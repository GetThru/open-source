# OpentelemetryDsl

Instrument functions with [OpenTelemetry](https://opentelemetry.io/).

## Distributed Tracing

[Traces](https://opentelemetry.io/docs/concepts/observability-primer/#distributed-traces) provide
a high-level overview of events that occur in a running production system, such as a REST request,
a running background job, or a PubSub event.

Traces are composed of one or more
[Spans](https://opentelemetry.io/docs/concepts/observability-primer/#spans), each representing an
individual unit of work. Spans allow us to track how long a unit of work took to execute, and
contain metadata used to organize and analyzing the same unit of work across multiple traces.

When exported to an observability platform, such as [Tempo](https://grafana.com/oss/tempo/) or
[Datadog](https://www.datadoghq.com/), we can search and visualize individual traces to better
understand the runtime characteristics of our application in production.

In short, traces help us find bottlenecks and errors in production, where traditional logging and
metrics cannot. Traces also help us navigate unfamiliar parts of our system by visualizing what is
happening where, when, and in what order.

## Generating Spans & Traces

In addition to the automatic instrumentation provided by libraries like `OpentelemetryPhoenix`, we
can define custom spans using the `OpentelemetryDSL.trace/1` macro:

```elixir
use OpentelemetryDSL

trace kind: :internal

def do_important_work do
  # ...
end
```

Doing so will generate a new span each time this function is executed. If a parent trace does not
exist yet, one is created.

You can add custom attributes, such as indicating if a cache was missed, using the `trace/1` macro
like so:

```elixir
trace attrs: [caching: :cache_miss]
```

Attributes makes it easy to organize and analyze spans across many traces in observability
platforms. For example, the above attribute could help us answer the question: "did this event use
our in-memory cache or not?"

But what if our function unexpectedly crashes? Functions annotated with the `trace/1` macro will
automatically have any errors raised captured and recorded in the current span before reraising
to the caller. This allows us to maintain the "let it crash" philosophy without sacrificing
observability.

## Tracing All Functions

As a convenience, if you would like to trace all functions defined in a module, you can use the
`trace_all/1` macro:

```elixir
use OpentelemetryDSL

trace_all kind: :internal

def fun_one do
  # ...
end

def fun_two do
  # ...
end
```

## Options

You can pass the following options to `use OpentelemetryDSL` to configure the calling module:

* `debug` - should debug statements be printed to stdout during compilation? Defaults to `false`.
