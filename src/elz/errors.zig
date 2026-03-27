/// `ElzError` is the set of all errors that can be returned by the Elz interpreter.
pub const ElzError = error{
    /// The interpreter failed to allocate memory.
    OutOfMemory,
    /// A symbol was not found in the current environment.
    SymbolNotFound,
    /// A string literal was not properly terminated.
    UnterminatedString,
    /// The parser reached the end of the input unexpectedly.
    UnexpectedEndOfInput,
    /// An open parenthesis was not matched with a closing parenthesis.
    UnmatchedOpenParen,
    /// A closing parenthesis was found without a matching open parenthesis.
    UnexpectedCloseParen,
    /// An invalid character literal was found (e.g., `#\invalid`).
    InvalidCharacterLiteral,
    /// The input to the parser was empty.
    EmptyInput,
    /// The `quote` special form was used with invalid arguments.
    QuoteInvalidArguments,
    /// The `if` special form was used with invalid arguments.
    IfInvalidArguments,
    /// The `define` special form was used with invalid arguments.
    DefineInvalidArguments,
    /// A symbol in a `define` form was invalid.
    DefineInvalidSymbol,
    /// The `lambda` special form was used with invalid arguments.
    LambdaInvalidArguments,
    /// The parameters of a `lambda` were invalid.
    LambdaInvalidParams,
    /// A procedure was called with the wrong number of arguments.
    WrongArgumentCount,
    /// A value that is not a procedure was called as if it were one.
    NotAFunction,
    /// A procedure was called with an argument of the wrong type.
    InvalidArgument,
    /// A division by zero was attempted.
    DivisionByZero,
    /// An error occurred in a foreign function.
    ForeignFunctionError,
    /// A feature is not yet implemented.
    NotImplemented,
    /// A dotted pair was used incorrectly.
    InvalidDottedPair,
    /// The `set!` special form was used with invalid arguments.
    SetInvalidArguments,
    /// A symbol in a `set!` form was invalid.
    SetInvalidSymbol,
    /// The execution budget (fuel) was exceeded.
    ExecutionBudgetExceeded,
    /// A required primitive function was not found in the environment.
    MissingPrimitive,
    /// A file was not found.
    FileNotFound,
    /// A file could not be written to.
    FileNotWritable,
    /// An I/O operation failed.
    IOError,
    /// The execution time limit was exceeded.
    TimeLimitExceeded,
    /// An escape continuation was invoked (internal, caught by call/ec).
    EscapeContinuationInvoked,
};
