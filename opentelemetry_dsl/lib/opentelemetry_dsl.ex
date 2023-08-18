# Copyright 2023 Toskr, Inc.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
defmodule OpentelemetryDSL do
  @moduledoc """
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
  """

  alias OpentelemetryDSL.Encoder

  @use_opts ~w[debug]a

  @doc false
  # See https://hexdocs.pm/elixir/Kernel.html#use/2
  defmacro __using__(opts \\ []) do
    line = __CALLER__.line
    file = __CALLER__.file

    validate_opts_keys!(opts, line, file, @use_opts)
    otel_opts = %{debug: parse_boolean_opt!(opts, line, file, :debug, false), line: line}

    quote do
      import OpentelemetryDSL
      require OpenTelemetry.Tracer
      Module.register_attribute(__MODULE__, :__trace__, accumulate: false)
      Module.register_attribute(__MODULE__, :__trace_all__, accumulate: false)
      Module.register_attribute(__MODULE__, :__function_traces__, accumulate: true)
      Module.put_attribute(__MODULE__, :on_definition, OpentelemetryDSL)
      Module.put_attribute(__MODULE__, :before_compile, OpentelemetryDSL)
      Module.put_attribute(__MODULE__, :__otel_opts__, unquote(Macro.escape(otel_opts)))
    end
  end

  @doc false
  # See https://hexdocs.pm/elixir/Module.html#module-on_definition
  def __on_definition__(env, kind, name, args, _guards, _body) do
    :ok = register_function_trace!(env, kind, name, args)
  end

  @doc false
  # See https://hexdocs.pm/elixir/Module.html#module-before_compile
  defmacro __before_compile__(env) do
    validate_dangling_traces!(env)

    %{debug: debug, line: line} = Module.get_attribute(env.module, :__otel_opts__)

    function_traces = Module.get_attribute(env.module, :__function_traces__)

    unless Enum.any?(function_traces) do
      warn!(line, env.file, """
      use OpentelemetryDSL called but no traces are defined, are you missing trace/1 or trace_all/1?
      """)
    end

    function_arities =
      for %{name: name, args: args} <- function_traces,
          uniq: true,
          do: {name, length(args)}

    defs =
      for %{
            module: module,
            kind: kind,
            name: name,
            args: args,
            line: line,
            file: file,
            trace: %{
              kind: span_kind,
              attrs: attrs,
              record_arguments: record_arguments,
              record_results: record_results,
              record_errors: record_errors
            }
          } <- function_traces do
        span_name = build_span_name(module, name, args)
        span_attrs = merge_source_code_attrs(attrs, module, name, args, file, line)
        positional_args = build_positional_args(args)

        quote do
          unquote(kind)(unquote(name)(unquote_splicing(positional_args))) do
            OpenTelemetry.Tracer.with_span unquote(span_name),
              kind: unquote(span_kind),
              attributes: unquote(Macro.escape(span_attrs)) do
              try do
                OpentelemetryDSL.__record_threads__()

                OpentelemetryDSL.__record_arguments__(
                  unquote(positional_args),
                  unquote(record_arguments)
                )

                result = super(unquote_splicing(positional_args))
                OpentelemetryDSL.__record_results__(result, unquote(record_results))
                result
              rescue
                exception ->
                  OpentelemetryDSL.__record_errors__(exception, unquote(record_errors))
                  reraise exception, __STACKTRACE__
              end
            end
          end
        end
      end

    overrides =
      quote do
        defoverridable unquote(function_arities)
      end

    build_ast(overrides, defs, debug)
  end

  @doc false
  # https://opentelemetry.io/docs/reference/specification/trace/semantic_conventions/span-general/#general-thread-attributes
  def __record_threads__ do
    attrs = %{
      "thread.name" => inspect(self()),
      "thread.id" => :erlang.system_info(:scheduler_id)
    }

    ctx = OpenTelemetry.Tracer.current_span_ctx()
    OpenTelemetry.Span.set_attributes(ctx, attrs)
    :ok
  end

  @doc false
  def __record_arguments__(args, record?) do
    if record? do
      attrs =
        args
        |> Enum.map(&Encoder.encode/1)
        |> Enum.with_index()
        |> Enum.reduce(Map.new(), fn
          {encoded, i}, acc when is_map(encoded) ->
            map =
              for {key, value} <- encoded,
                  into: %{},
                  do: {"code.arguments.arg#{i}.#{key}", value}

            Map.merge(acc, map)

          {encoded, i}, acc ->
            Map.put(acc, "code.arguments.arg#{i}", encoded)
        end)

      ctx = OpenTelemetry.Tracer.current_span_ctx()
      OpenTelemetry.Span.set_attributes(ctx, attrs)
    end

    :ok
  end

  @doc false
  def __record_results__(result, record?) do
    if record? do
      ctx = OpenTelemetry.Tracer.current_span_ctx()
      OpenTelemetry.Span.set_attribute(ctx, "code.result", Encoder.encode(result))
    end

    :ok
  end

  @doc false
  def __record_errors__(exception, record?) do
    if record? do
      ctx = OpenTelemetry.Tracer.current_span_ctx()
      OpenTelemetry.Span.record_exception(ctx, exception)

      OpenTelemetry.Span.set_status(
        ctx,
        OpenTelemetry.status(:error, Exception.message(exception))
      )
    end

    :ok
  end

  @doc """
  Merges a map of values into the current span's attribute list.

  Useful for adding dynamic values (those only known at runtime) into a span created via the
  `trace/1` macro.

  See `OpenTelemetry.Span.set_attributes/2`.
  """
  @spec trace_attrs(keyword()) :: :ok
  def trace_attrs(attrs) when is_list(attrs) do
    encoded =
      for {key, value} <- attrs, into: %{}, do: {Atom.to_string(key), Encoder.encode(value)}

    ctx = OpenTelemetry.Tracer.current_span_ctx()
    OpenTelemetry.Span.set_attributes(ctx, encoded)
    :ok
  end

  @doc """
  Annotates a function to generate an OpenTelemetry span upon invocation.

  The name of the generated span follows the remote function syntax, e.g. `Kernel.elem/2`.

  ## Options

  * `:attrs` - a keyword list of span attributes. Defaults to `[]`.
  * `:kind` - an atom defining the span kind. Defaults to `:internal`.
  * `:record_arguments` - record arguments passed to the function when invoked? Defaults to `false`.
  * `:record_results` - record the result of the function when invoked? Defaults to `false`.
  * `:record_errors` - record the exception of the function when invoked? Defaults to `true`.

  ## Default Span Attributes

  By default, the following attributes are added to each span created with `trace/1`:

  * `code.filepath` - the relative path of the source file.
  * `code.lineno` - the source file line the annotated function is defined.
  * `code.function` - the name and arity of the annotated function.
  * `code.namespace` - the module of the annotated function.
  * `thread.id` - the BEAM scheduler running the process executing the annotated function.
  * `thread.name` - the `PID` of the process executing the annotated function.

  These attributes follow the OpenTelemetry [semantic convention](https://opentelemetry.io/docs/reference/specification/trace/semantic_conventions/span-general/)
  for Spans as much as possible.

  ## Limitations

  There are a couple scenarios where you may want to leverage the `OpenTelemetry` SDK directly,
  or in addition to, the `trace/1` macro.

  ### Dynamic Span Attributes

  Since macros are expanded during compilation, we can only define static attribute values using
  the `:attrs` option. To solve this, you can call the `trace_attr/1` helper function inside the
  annotated function body:

  ```elixir
  trace kind: :internal

  def function do
    # ...
    trace_attrs key: value
    # ...
  end
  ```

  Each time `function/3` is invoked, a new span is created and the runtime values of `value` are
  merged into the span's attribute list.

  ### Dynamic Span Status

  By default, any exception raised by a function annotated with `trace/1` will set the status of the
  current span to `error` along with the message of the raised exception. If you would like to
  customize this behavior, you must do the following:

  1. Set the `trace/1` option `:record_errors` to `false`.
  2. Manually set the span status by calling `OpenTelemetry.Span.set_status/2` in the body of the
  annotated function.

  ### Propagating Spans Across Multiple Elixir Processes

  `OpenTelemetry` stores the current, active span in the process dictionary (see `Process.get/0`),
  meaning any child processes spawned, regardless if they are linked or not, will not be tracked
  as part of the spawning process' span.

  To propagate span context from a parent process to one or more children, you can use the
  `OpentelemetryProcessPropagator` library.
  """
  defmacro trace(opts \\ []) when is_list(opts) do
    quote bind_quoted: [opts: opts] do
      OpentelemetryDSL.__trace__!(__MODULE__, __ENV__.line, __ENV__.file, opts)
    end
  end

  @doc """
  Annotates all public functions defined in a module to generate OpenTelemetry traces
  upon invocation.

  See `trace/1` for more information.
  """
  defmacro trace_all(opts \\ []) when is_list(opts) do
    quote bind_quoted: [opts: opts] do
      OpentelemetryDSL.__trace_all__!(__MODULE__, __ENV__.line, __ENV__.file, opts)
    end
  end

  @doc false
  def __trace__!(module, line, file, opts) do
    validate_multiple_traces!(module, line, file)
    trace_opts = parse_trace_opts!(opts, line, file)
    trace = Map.merge(%{line: line}, trace_opts)
    Module.put_attribute(module, :__trace__, trace)
    :ok
  end

  @doc false
  def __trace_all__!(module, line, file, opts) do
    validate_multiple_trace_alls!(module, line, file)
    trace_opts = parse_trace_opts!(opts, line, file)
    trace_all = Map.merge(%{line: line}, trace_opts)
    Module.put_attribute(module, :__trace_all__, trace_all)
    :ok
  end

  defp register_function_trace!(%{module: module, line: line, file: file}, kind, name, args) do
    trace =
      if kind in [:def, :defmacro] do
        pop_trace!(module) || get_trace_all(module)
      else
        pop_trace!(module)
      end

    if trace do
      Module.put_attribute(module, :__function_traces__, %{
        trace: trace,
        name: name,
        args: args,
        kind: kind,
        line: line,
        file: file,
        module: module
      })
    end

    :ok
  end

  defp get_trace(module) do
    Module.get_attribute(module, :__trace__)
  end

  defp pop_trace!(module) do
    trace = Module.get_attribute(module, :__trace__)
    Module.delete_attribute(module, :__trace__)
    Module.register_attribute(module, :__trace__, accumulate: false)
    trace
  end

  defp get_trace_all(module) do
    Module.get_attribute(module, :__trace_all__)
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp build_positional_args(args) do
    args
    |> Enum.with_index()
    |> Enum.map(fn
      {{_, meta, _}, i} -> {:"arg#{i}", meta, nil}
      {_, i} -> {:"arg#{i}", [], nil}
    end)
  end

  defp build_span_name(module, name, args) do
    "#{inspect(module)}.#{name}/#{length(args)}"
  end

  # https://opentelemetry.io/docs/reference/specification/trace/semantic_conventions/span-general/#source-code-attributes
  defp merge_source_code_attrs(span_attrs, mod, fun, args, file, line) do
    Map.merge(span_attrs, %{
      "code.namespace" => inspect(mod),
      "code.function" => "#{fun}/#{length(args)}",
      "code.filepath" => build_relative_path(file),
      "code.lineno" => line
    })
  end

  defp build_ast(overrides, defs, debug?) do
    for def <- defs, debug?, do: def |> Macro.to_string() |> IO.puts()
    {:__block__, [], [overrides | defs]}
  end

  defp build_relative_path(file) do
    ".#{String.trim_leading(file, File.cwd!())}"
  end

  @trace_opts ~w[attrs kind record_arguments record_results]a
  # https://opentelemetry.io/docs/reference/specification/trace/api/#spankind
  @span_kinds ~w[client server producer consumer internal]a

  defp parse_trace_opts!(opts, line, file) do
    validate_opts_keys!(opts, line, file, @trace_opts)

    kind = Keyword.get(opts, :kind, :internal)

    unless kind in @span_kinds do
      compile_error!(line, file, """
      trace option :kind must be one of #{inspect(@span_kinds)}, got: #{inspect(kind)}
      """)
    end

    record_arguments = parse_boolean_opt!(opts, line, file, :record_arguments, false)
    record_results = parse_boolean_opt!(opts, line, file, :record_results, false)
    record_errors = parse_boolean_opt!(opts, line, file, :record_errors, true)

    encoded =
      for {key, value} <- Keyword.get(opts, :attrs, []),
          into: %{},
          do: {Atom.to_string(key), Encoder.encode(value)}

    %{
      attrs: encoded,
      kind: kind,
      record_arguments: record_arguments,
      record_results: record_results,
      record_errors: record_errors
    }
  end

  defp validate_opts_keys!(opts, line, file, inclusion) do
    for key <- Keyword.keys(opts), key not in inclusion do
      compile_error!(line, file, """
      unsupported option #{inspect(key)}, must be one of #{inspect(inclusion)}
      """)
    end
  end

  defp parse_boolean_opt!(opts, line, file, name, default) do
    opt = Keyword.get(opts, name, default)

    unless is_boolean(opt) do
      compile_error!(line, file, """
      option #{inspect(name)} must be a :boolean, got: #{inspect(opt)}"
      """)
    end

    opt
  end

  defp validate_multiple_traces!(module, line, file) do
    if get_trace(module) do
      compile_error!(line, file, """
      cannot define multiple traces for the same function
      """)
    end
  end

  defp validate_multiple_trace_alls!(module, line, file) do
    trace_all = get_trace_all(module)

    if trace_all do
      compile_error!(line, file, """
      cannot define multiple trace_alls for the same module
      """)
    end
  end

  defp validate_dangling_traces!(%{module: module, file: file}) do
    trace = get_trace(module)

    if trace do
      compile_error!(trace.line, file, """
      a trace must be defined before a function
      """)
    end
  end

  defp compile_error!(line, file, msg) do
    raise CompileError, line: line, file: file, description: msg
  end

  defp warn!(line, file, msg) do
    IO.warn(msg, file: file, line: line)
  end
end
