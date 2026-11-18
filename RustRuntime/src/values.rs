use std::collections::{BTreeMap, HashMap};

use convex::{FunctionResult, Value};
use convex_sync_types::UdfPath;

use crate::RuntimeError;

/// A validated function call: a parseable Convex path and decoded arguments.
pub(crate) struct FunctionRequest {
    pub(crate) path: String,
    pub(crate) arguments: BTreeMap<String, Value>,
}

impl FunctionRequest {
    /// Validates `path` and decodes each Convex-encoded JSON argument.
    ///
    /// Upstream convex-mobile used `expect` here, aborting the process on malformed input.
    /// Error messages name the offending argument but never include its value.
    pub(crate) fn parse(
        path: String,
        arguments: HashMap<String, String>,
    ) -> Result<Self, RuntimeError> {
        if let Err(error) = path.parse::<UdfPath>() {
            return Err(RuntimeError::InvalidRequest {
                message: format!("Invalid Convex function path {path:?}: {error:#}"),
            });
        }
        let mut decoded = BTreeMap::new();
        for (name, encoded) in arguments {
            let value = decode_argument(&name, &encoded)?;
            decoded.insert(name, value);
        }
        Ok(Self {
            path,
            arguments: decoded,
        })
    }
}

fn decode_argument(name: &str, encoded: &str) -> Result<Value, RuntimeError> {
    let json: serde_json::Value =
        serde_json::from_str(encoded).map_err(|error| RuntimeError::InvalidRequest {
            message: format!("Argument {name:?} is not valid JSON: {error}"),
        })?;
    Value::try_from(json).map_err(|error| RuntimeError::InvalidRequest {
        message: format!("Argument {name:?} is not a valid Convex value: {error:#}"),
    })
}

/// Encodes `value` with Convex's JSON envelopes (`$integer`, `$float`, `$bytes`).
pub(crate) fn encode_value(value: Value) -> Result<String, RuntimeError> {
    serde_json::to_string(&serde_json::Value::from(value)).map_err(|error| RuntimeError::Internal {
        message: format!("Could not encode a Convex value as JSON: {error}"),
    })
}

/// Converts a one-shot function result into its encoded value or a categorized error.
pub(crate) fn function_output(result: FunctionResult) -> Result<String, RuntimeError> {
    match result {
        FunctionResult::Value(value) => encode_value(value),
        FunctionResult::ConvexError(error) => Err(RuntimeError::Application {
            data: encode_value(error.data)?,
        }),
        FunctionResult::ErrorMessage(message) => Err(RuntimeError::Server { message }),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, HashMap};

    use convex::{ConvexError, FunctionResult, Value};

    use super::{encode_value, function_output, FunctionRequest};
    use crate::RuntimeError;

    fn parse(path: &str, arguments: &[(&str, &str)]) -> Result<FunctionRequest, RuntimeError> {
        let arguments = arguments
            .iter()
            .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
            .collect::<HashMap<_, _>>();
        FunctionRequest::parse(path.to_owned(), arguments)
    }

    fn rejection(path: &str, arguments: &[(&str, &str)]) -> String {
        match parse(path, arguments) {
            Err(RuntimeError::InvalidRequest { message }) => message,
            Err(other) => panic!("expected InvalidRequest, got {other:?}"),
            Ok(_) => panic!("expected InvalidRequest, got a request"),
        }
    }

    #[test]
    fn decodes_convex_envelopes_at_every_depth() {
        let request = parse(
            "messages:list",
            &[
                ("flag", "false"),
                ("count", r#"{"$integer":"AQAAAAAAAAA="}"#),
                ("ratio", "42.5"),
                ("negativeZero", r#"{"$float":"AAAAAAAAAIA="}"#),
                ("bytes", r#"{"$bytes":"AAEC"}"#),
                (
                    "nested",
                    r#"{"a key":[null,{"$integer":"/////////38="},{"$float":"AAAAAAAA8H8="}]}"#,
                ),
            ],
        )
        .expect("valid arguments");

        assert_eq!(request.path, "messages:list");
        let arguments = request.arguments;
        assert_eq!(arguments["flag"], Value::Boolean(false));
        assert_eq!(arguments["count"], Value::Int64(1));
        assert_eq!(arguments["ratio"], Value::Float64(42.5));
        match arguments["negativeZero"] {
            Value::Float64(zero) => assert!(zero == 0.0 && zero.is_sign_negative()),
            ref other => panic!("expected Float64, got {other:?}"),
        }
        assert_eq!(arguments["bytes"], Value::Bytes(vec![0, 1, 2]));
        assert_eq!(
            arguments["nested"],
            Value::Object(BTreeMap::from([(
                "a key".to_owned(),
                Value::Array(vec![
                    Value::Null,
                    Value::Int64(i64::MAX),
                    Value::Float64(f64::INFINITY),
                ]),
            )])),
        );
    }

    #[test]
    fn rejects_invalid_json_without_echoing_the_value() {
        let message = rejection("messages:list", &[("body", "{\"secret\": ")]);
        assert!(message.contains("\"body\""), "{message}");
        assert!(message.contains("not valid JSON"), "{message}");
        assert!(!message.contains("secret"), "{message}");
    }

    #[test]
    fn rejects_invalid_convex_values() {
        for encoded in [
            r#"{"$integer":"not base64"}"#,
            r#"{"$integer":"AQ=="}"#,
            r#"{"$bytes":7}"#,
            r#"{"$float":"AAAAAAAA8D8="}"#,
            r#"{"$set":[]}"#,
            r#"{"$map":[]}"#,
            "123456789012345678901234567890e999999",
        ] {
            let message = rejection("messages:list", &[("value", encoded)]);
            assert!(message.contains("\"value\""), "{encoded}: {message}");
        }
    }

    #[test]
    fn rejects_excessive_nesting_without_overflowing_the_stack() {
        let encoded = format!("{}{}", "[".repeat(100_000), "]".repeat(100_000));
        let message = rejection("messages:list", &[("deep", &encoded)]);
        assert!(message.contains("not valid JSON"), "{message}");
    }

    #[test]
    fn rejects_invalid_function_paths() {
        for path in ["", "messages:", "messages:list:extra", "../messages:list"] {
            let message = rejection(path, &[]);
            assert!(
                message.contains("Invalid Convex function path"),
                "{path:?}: {message}"
            );
        }
    }

    #[test]
    fn encodes_special_values_with_envelopes() {
        let value = Value::Array(vec![
            Value::Int64(-1),
            Value::Float64(-0.0),
            Value::Float64(f64::NAN),
            Value::Float64(1.5),
            Value::Bytes(vec![255]),
            Value::Null,
        ]);
        assert_eq!(
            encode_value(value).expect("encodable"),
            r#"[{"$integer":"//////////8="},{"$float":"AAAAAAAAAIA="},{"$float":"AAAAAAAA+H8="},1.5,{"$bytes":"/w=="},null]"#,
        );
    }

    #[test]
    fn categorizes_function_results() {
        assert_eq!(
            function_output(FunctionResult::Value(Value::Null)).expect("null is a value"),
            "null",
        );
        match function_output(FunctionResult::ErrorMessage("boom".to_owned())) {
            Err(RuntimeError::Server { message }) => assert_eq!(message, "boom"),
            other => panic!("expected Server, got {other:?}"),
        }
        let application = FunctionResult::ConvexError(ConvexError {
            message: "rejected".to_owned(),
            data: Value::Object(BTreeMap::from([("code".to_owned(), Value::Int64(7))])),
        });
        match function_output(application) {
            Err(RuntimeError::Application { data }) => {
                assert_eq!(data, r#"{"code":{"$integer":"BwAAAAAAAAA="}}"#)
            }
            other => panic!("expected Application, got {other:?}"),
        }
    }
}
