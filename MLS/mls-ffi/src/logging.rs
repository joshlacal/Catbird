use std::sync::RwLock;
use once_cell::sync::Lazy;
use crate::types::MLSLogger;

/// Global logger instance that can be set from Swift
static LOGGER: Lazy<RwLock<Option<Box<dyn MLSLogger>>>> = Lazy::new(|| RwLock::new(None));

/// Set the global logger (called from Swift)
pub fn set_logger(logger: Box<dyn MLSLogger>) {
    if let Ok(mut guard) = LOGGER.write() {
        *guard = Some(logger);
    }
}

/// Log a debug message
#[macro_export]
macro_rules! debug_log {
    ($($arg:tt)*) => {
        $crate::logging::log_message("debug", &format!($($arg)*));
    };
}

/// Log an info message
#[macro_export]
macro_rules! info_log {
    ($($arg:tt)*) => {
        $crate::logging::log_message("info", &format!($($arg)*));
    };
}

/// Log a warning message
#[macro_export]
macro_rules! warn_log {
    ($($arg:tt)*) => {
        $crate::logging::log_message("warning", &format!($($arg)*));
    };
}

/// Log an error message
#[macro_export]
macro_rules! error_log {
    ($($arg:tt)*) => {
        $crate::logging::log_message("error", &format!($($arg)*));
    };
}

/// Internal function to send log messages to Swift
pub fn log_message(level: &str, message: &str) {
    if let Ok(guard) = LOGGER.read() {
        if let Some(logger) = guard.as_ref() {
            logger.log(level.to_string(), message.to_string());
        }
        // If no logger set, silently ignore (no-op on iOS without stderr)
    }
}

// Re-export macros
pub use debug_log;
pub use info_log;
pub use warn_log;
pub use error_log;
