# LLM Error Handling & Retry: Best Practices Design

> **Scope**: Structured error classification, automatic retry mechanisms, fallback strategies, and recovery patterns for LLM client libraries and agent frameworks.
>
> **Synthesized from**: pydantic-ai, langchain, pi-mono, kosong, republic

---

## Core Philosophy

**Errors are data. Recovery is strategy. Decisions are context-dependent.**

This design philosophy combines:
- **Type safety** (compile-time) for precise error handling
- **Strategy flexibility** (runtime) for adaptable recovery
- **Observability** for production debugging
- **Testability** for chaos engineering

---

## 1. Dual-Layer Error System

### 1.1 Type Layer: Precise Error Types

```rust
/// Hierarchical error types for match-based handling
pub enum LLMError {
    /// Developer misuse (bad API key, invalid model name)
    User {
        kind: UserErrorKind,
        message: String,
    },

    /// Runtime errors during LLM interaction
    Runtime(RuntimeError),

    /// Wrapped error with recovery strategy attached
    Retryable {
        source: Box<LLMError>,
        strategy: RetryStrategy,
    },
}

pub enum RuntimeError {
    Connection {
        endpoint: String,
        source: Option<Box<dyn std::error::Error>>,
    },
    Status {
        code: u16,
        body: Option<String>,
        provider: ProviderId,
    },
    Validation {
        field: String,
        reason: String,
    },
    TokenLimit {
        requested: usize,
        max_tokens: Option<usize>,
    },
    ContentFilter {
        provider: ProviderId,
        reason: Option<String>,
    },
    ToolCallIncomplete {
        partial: ToolCall,
    },
}

pub enum UserErrorKind {
    InvalidApiKey,
    ModelNotFound,
    InvalidParameter,
    UnsupportedFeature,
}
```

**Design Rationale**:
- Explicit types enable exhaustive match handling
- Rich context (status codes, provider IDs) aids debugging
- Separate user errors from runtime errors for different handling paths

### 1.2 Classification Layer: Strategy-Driven Categories

```rust
/// Error classifications for recovery strategy selection
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorClass {
    /// Unrecoverable, abort immediately
    Fatal,

    /// Temporary failure, retry with same model (429, 408, 503)
    Transient,

    /// Configuration issue, abort and alert (401, 403)
    Config,

    /// Provider issue, may fallback or retry (5xx, timeout)
    Switchable,

    /// Token limit, special compaction handling
    Capacity,

    /// Content policy violation
    Policy,
}

/// Trait for classifying errors into strategy categories
pub trait ErrorClassifier: Send + Sync {
    fn classify(&self, error: &LLMError) -> ErrorClass;
}
```

**Design Rationale**:
- Classification separates "what happened" from "what to do"
- Enables user-injectable policy (business-specific rules)
- Simplifies decision logic by working with enums instead of types

---

## 2. Multi-Level Classification Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│ Level 1: User Classifier (highest priority)                  │
│ - Business-specific mappings                                 │
│ - Provider-specific quirks                                   │
├─────────────────────────────────────────────────────────────┤
│ Level 2: Library Exception Mapping                           │
│ - openai::APIStatusError → Status { code }                  │
│ - anthropic::RateLimitError → Transient                     │
│ - any_llm::AnyLLMError → mapped variants                    │
├─────────────────────────────────────────────────────────────┤
│ Level 3: HTTP Status Classification                          │
│ - 429 / 408 → Transient (rate limit / timeout)              │
│ - 401 / 403 → Config (auth / permission)                    │
│ - 5xx → Switchable (server errors)                          │
├─────────────────────────────────────────────────────────────┤
│ Level 4: Text Signature Matching                             │
│ - Regex patterns for non-standard providers                  │
│ - "rate limit" / "too many requests" / "quota exceeded"     │
└─────────────────────────────────────────────────────────────┘
```

```rust
pub struct TieredClassifier {
    user: Option<Box<dyn ErrorClassifier>>,
    http: HttpStatusClassifier,
    text: TextSignatureClassifier,
}

impl ErrorClassifier for TieredClassifier {
    fn classify(&self, error: &LLMError) -> ErrorClass {
        // Level 1: User-defined rules
        if let Some(user) = &self.user {
            let class = user.classify(error);
            if class != ErrorClass::Unknown {
                return class;
            }
        }

        // Level 2-4: Built-in classifiers...
        self.http.classify(error)
            .or_else(|| self.text.classify(error))
            .unwrap_or(ErrorClass::Fatal)
    }
}
```

---

## 3. Recoverability as a Trait

```rust
/// Recoverable errors can provide recovery strategies
pub trait Recoverable: std::error::Error {
    /// Determine the recovery strategy for this error
    fn recovery_strategy(&self, ctx: &RecoveryContext) -> RecoveryStrategy;

    /// Whether this error can be fed back to LLM for correction
    /// (inspired by langchain's send_to_llm)
    fn is_llm_fixable(&self) -> bool {
        false
    }

    /// Get suggested fixes for user-facing display
    fn suggestions(&self) -> Vec<String> {
        vec![]
    }
}

pub struct RecoveryContext {
    pub attempt_count: u32,
    pub fallback_available: bool,
    pub max_retries: u32,
    pub elapsed: Duration,
}

pub enum RecoveryStrategy {
    /// Retry with exponential backoff
    Retry {
        backoff: BackoffConfig,
        max_attempts: u32,
    },

    /// Switch to fallback model
    Fallback {
        target: ModelId,
        propagate_error: bool,  // langchain's exception_key pattern
    },

    /// Compact context and retry (token limit special case)
    Compaction {
        strategy: CompactionStrategy,
    },

    /// Delegate to external handler (human approval, etc.)
    Delegate {
        handler: HandlerId,
        timeout: Duration,
    },

    /// Abort the operation
    Abort {
        reason: AbortReason,
    },
}
```

---

## 4. Pluggable Backoff Strategies

```rust
pub trait BackoffStrategy: Send + Sync {
    /// Calculate next delay, return None to stop retrying
    fn next_delay(&self, ctx: &RetryContext) -> Option<Duration>;
}

pub struct RetryContext {
    pub attempt: u32,
    pub error: &LLMError,
    pub last_delay: Option<Duration>,
    pub server_requested_delay: Option<Duration>,
}

/// Fixed interval backoff
pub struct FixedBackoff {
    pub delay: Duration,
}

/// Exponential backoff with optional jitter
pub struct ExponentialBackoff {
    pub initial: Duration,
    pub multiplier: f64,
    pub max_delay: Duration,
    pub jitter: JitterMode,
}

pub enum JitterMode {
    None,
    Full,       // Random [0, calculated]
    Equal,      // Random [calculated/2, calculated]
    Decorrelated, // max(min_delay, random * last_delay * 3)
}

/// Respect server's Retry-After header (inspired by pi-mono + pydantic-ai)
pub struct RespectRetryAfter {
    pub fallback: Box<dyn BackoffStrategy>,
    pub max_delay: Duration,
    pub respect_header: bool,  // false = use fallback only
}

impl BackoffStrategy for RespectRetryAfter {
    fn next_delay(&self, ctx: &RetryContext) -> Option<Duration> {
        // Priority: server_requested_delay > fallback calculation
        let delay = ctx.server_requested_delay
            .and_then(|d| if self.respect_header { Some(d) } else { None })
            .or_else(|| self.fallback.next_delay(ctx))?
            .min(self.max_delay);

        Some(delay)
    }
}
```

### Retry-After Extraction (comprehensive)

```rust
pub fn extract_retry_delay(error: &LLMError, headers: &HeaderMap) -> Option<Duration> {
    // 1. Standard Retry-After header (seconds or HTTP date)
    if let Some(value) = headers.get("retry-after") {
        if let Ok(text) = value.to_str() {
            // Try parsing as integer seconds
            if let Ok(seconds) = text.parse::<u64>() {
                return Some(Duration::from_secs(seconds));
            }
            // Try parsing as HTTP date
            if let Ok(date) = parse_http_date(text) {
                return Some(date - SystemTime::now());
            }
        }
    }

    // 2. Provider-specific headers
    if let Some(value) = headers.get("x-ratelimit-reset") {
        // Unix timestamp
        if let Ok(ts) = value.to_str().and_then(|s| s.parse::<u64>().ok()) {
            let reset_time = SystemTime::UNIX_EPOCH + Duration::from_secs(ts);
            return reset_time.duration_since(SystemTime::now()).ok();
        }
    }

    if let Some(value) = headers.get("x-ratelimit-reset-after") {
        // Seconds from now
        if let Ok(seconds) = value.to_str().and_then(|s| s.parse::<u64>().ok()) {
            return Some(Duration::from_secs(seconds));
        }
    }

    // 3. Error message pattern matching (pi-mono approach)
    if let Some(text) = error.error_message() {
        // "Your quota will reset after 18h31m10s"
        if let Some(caps) = RE_RESET_DURATION.captures(text) {
            return Some(parse_duration(&caps));
        }
        // "Please retry in 2s"
        if let Some(caps) = RE_RETRY_IN.captures(text) {
            return Some(parse_duration(&caps));
        }
        // "retryDelay": "34.074s" (JSON)
        if let Some(caps) = RE_JSON_RETRY_DELAY.captures(text) {
            return Some(parse_duration(&caps));
        }
    }

    None
}
```

---

## 5. Decision Engine

```rust
/// Central decision logic for error recovery
pub struct DecisionEngine {
    classifier: Box<dyn ErrorClassifier>,
    max_retries: u32,
    backoff: Box<dyn BackoffStrategy>,
    fallbacks: Vec<ModelId>,
}

pub enum Decision {
    Retry { delay: Duration },
    Fallback { target: ModelId, carry_error: bool },
    Compact { strategy: CompactionStrategy },
    Abort { reason: AbortReason },
}

impl DecisionEngine {
    pub fn decide(&self, error: &LLMError, ctx: &ExecutionContext) -> Decision {
        let class = self.classifier.classify(error);
        let attempts = ctx.current_attempts();
        let has_fallback = !self.fallbacks.is_empty() && ctx.fallback_index() < self.fallbacks.len();

        match class {
            ErrorClass::Fatal => Decision::Abort {
                reason: AbortReason::FatalError
            },

            ErrorClass::Config => Decision::Abort {
                reason: AbortReason::Configuration
            },

            ErrorClass::Capacity => Decision::Compact {
                strategy: CompactionStrategy::SummarizeOldest
            },

            ErrorClass::Policy => Decision::Abort {
                reason: AbortReason::ContentPolicy
            },

            ErrorClass::Transient if attempts < self.max_retries => {
                let retry_ctx = RetryContext {
                    attempt: attempts,
                    error,
                    last_delay: ctx.last_delay(),
                    server_requested_delay: ctx.server_requested_delay(),
                };
                match self.backoff.next_delay(&retry_ctx) {
                    Some(delay) => Decision::Retry { delay },
                    None => Decision::Abort { reason: AbortReason::BackoffExhausted },
                }
            }

            ErrorClass::Transient | ErrorClass::Switchable if has_fallback => {
                Decision::Fallback {
                    target: self.fallbacks[ctx.fallback_index()].clone(),
                    carry_error: true,  // Allow fallback to see the error
                }
            }

            _ => Decision::Abort { reason: AbortReason::Exhausted },
        }
    }
}
```

---

## 6. Callback & Observability System

```rust
/// Callback trait for observing error handling (inspired by langchain)
pub trait CallbackHandler: Send + Sync {
    fn on_llm_start(&self, model: &ModelId, request: &Request);
    fn on_llm_end(&self, model: &ModelId, response: &Response);

    fn on_llm_error(&self, model: &ModelId, error: &LLMError);

    fn on_retry(&self,
        model: &ModelId,
        error: &LLMError,
        attempt: u32,
        next_delay: Duration
    );

    fn on_fallback(&self,
        from: &ModelId,
        to: &ModelId,
        error: &LLMError
    );

    fn on_compaction(&self,
        strategy: &CompactionStrategy,
        tokens_removed: usize
    );
}

/// Tracing integration
#[derive(Debug)]
pub struct RetryEvent {
    pub run_id: Uuid,
    pub parent_run_id: Option<Uuid>,
    pub model: ModelId,
    pub attempt: u32,
    pub error_class: ErrorClass,
    pub delay_ms: u64,
    pub timestamp: SystemTime,
}
```

---

## 7. Context Overflow Handling

```rust
/// Specialized handling for token limit errors (inspired by pydantic-ai)
pub struct OverflowHandler {
    pub patterns: Vec<Regex>,  // Provider-specific error patterns
}

impl OverflowHandler {
    /// Detect if error is a context overflow
    pub fn is_overflow(&self, error: &LLMError) -> bool {
        let message = match error {
            LLMError::Runtime(RuntimeError::TokenLimit { .. }) => return true,
            _ => error.to_string(),
        };

        // Pattern matching for various providers
        self.patterns.iter().any(|re| re.is_match(&message))
    }

    /// Default patterns (pi-mono's comprehensive list)
    pub fn default_patterns() -> Vec<Regex> {
        vec![
            r"prompt is too long",                           // Anthropic
            r"input is too long for requested model",        // Amazon Bedrock
            r"exceeds the context window",                   // OpenAI
            r"input token count.*exceeds the maximum",       // Google
            r"maximum prompt length is \d+",                 // xAI
            r"reduce the length of the messages",            // Groq
            r"maximum context length is \d+ tokens",         // OpenRouter
            r"exceeded model token limit",                   // Kimi
            r"context[_ ]length[_ ]exceeded",                // Generic
        ].into_iter()
         .map(|p| Regex::new(p).unwrap())
         .collect()
    }
}

/// Compaction strategies
pub enum CompactionStrategy {
    /// Remove oldest messages
    DropOldest { keep_recent: usize },

    /// Summarize oldest messages
    SummarizeOldest,

    /// Compress via summary model
    CompressWithModel { model: ModelId },

    /// User-defined strategy
    Custom(Box<dyn CompactionFn>),
}
```

---

## 8. Testing & Chaos Engineering

```rust
/// Chaos testing configuration (inspired by kosong)
pub struct ChaosConfig {
    pub error_probability: f64,
    pub error_types: Vec<InjectedError>,
    pub latency_mean: Option<Duration>,
    pub latency_stddev: Option<Duration>,
}

pub enum InjectedError {
    Status { code: u16, body: String },
    Timeout,
    ConnectionReset,
    CorruptResponse,
}

/// Test helper for simulating error scenarios
pub struct ChaosProvider<P: LLMProvider> {
    inner: P,
    config: ChaosConfig,
    rng: ThreadRng,
}

impl<P: LLMProvider> LLMProvider for ChaosProvider<P> {
    async fn complete(&self, request: Request) -> Result<Response, LLMError> {
        // Inject latency
        if let Some(mean) = self.config.latency_mean {
            let jitter = self.config.latency_stddev
                .map(|s| s.as_millis() as f64 * self.rng.sample::<f64, _>(StandardNormal))
                .unwrap_or(0.0) as u64;
            sleep(Duration::from_millis(mean.as_millis() as u64 + jitter)).await;
        }

        // Inject error
        if self.rng.gen::<f64>() < self.config.error_probability {
            return Err(self.generate_error());
        }

        self.inner.complete(request).await
    }
}
```

---

## 9. Complete Configuration

```rust
pub struct ErrorHandlingConfig {
    /// Maximum retries per model
    pub max_retries: u32,

    /// Backoff strategy
    pub backoff: Box<dyn BackoffStrategy>,

    /// Maximum delay to wait (pi-mono's maxRetryDelayMs)
    pub max_retry_delay: Duration,

    /// Fallback model chain
    pub fallbacks: Vec<ModelId>,

    /// Whether to pass errors to fallbacks (langchain pattern)
    pub propagate_errors_to_fallbacks: bool,

    /// Custom classifier
    pub classifier: Option<Box<dyn ErrorClassifier>>,

    /// Callback handlers
    pub callbacks: Vec<Arc<dyn CallbackHandler>>,

    /// Token limit handling
    pub compaction: Option<CompactionConfig>,

    /// Whether to feed errors back to LLM for correction
    pub enable_llm_error_recovery: bool,
}

impl Default for ErrorHandlingConfig {
    fn default() -> Self {
        Self {
            max_retries: 3,
            backoff: Box::new(ExponentialBackoff {
                initial: Duration::from_secs(1),
                multiplier: 2.0,
                max_delay: Duration::from_secs(60),
                jitter: JitterMode::Decorrelated,
            }),
            max_retry_delay: Duration::from_secs(60),
            fallbacks: vec![],
            propagate_errors_to_fallbacks: true,
            classifier: None,
            callbacks: vec![],
            compaction: None,
            enable_llm_error_recovery: false,
        }
    }
}
```

---

## 10. Summary: Design Decision Matrix

| Decision | Recommendation | Primary Source |
|----------|----------------|----------------|
| **Error Types** | Hierarchical enum with rich context | pydantic-ai |
| **Classification** | Separate `ErrorClass` enum | republic |
| **Classifier Architecture** | 4-tier pipeline (user → library → HTTP → text) | republic + pi-mono |
| **Recoverability** | Trait-based, context-aware | kosong + pydantic-ai |
| **Backoff** | Pluggable with `Retry-After` support | pi-mono + pydantic-ai |
| **Decision Logic** | Centralized `DecisionEngine` | republic |
| **Fallback** | Model chain with error propagation | langchain |
| **Token Limit** | Special `Compaction` strategy | pydantic-ai |
| **Observability** | Callback system + structured events | langchain |
| **Testing** | Built-in chaos injection | kosong |

---

## Related Files

- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/learns/structured-errors-retry.md` - Comparative analysis of all frameworks
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/exceptions.py`
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/republic/src/republic/core/execution.py`
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pi-mono/packages/ai/src/providers/google-gemini-cli.ts`
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/kimi-cli/packages/kosong/src/kosong/chat_provider/chaos.py`

---

*Created: 2026-02-26*
