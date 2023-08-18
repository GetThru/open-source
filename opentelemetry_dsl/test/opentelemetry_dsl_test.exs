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
defmodule OpentelemetryDSLTest do
  use ExUnit.Case, async: false

  # Much of this is based on https://github.com/open-telemetry/opentelemetry-erlang/blob/main/test/otel_tests.exs

  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  describe "__using__/1" do
    test "logs expanded macros to stdout when debug is enabled" do
      stdout =
        ExUnit.CaptureIO.capture_io(fn ->
          defmodule Debugging do
            use OpentelemetryDSL, debug: true

            trace(kind: :internal)

            def fun(foo), do: foo
          end
        end)

      assert stdout == ~S'''
             def fun(arg0) do
               OpenTelemetry.Tracer.with_span "OpentelemetryDSLTest.Debugging.fun/1",
                 kind: :internal,
                 attributes: %{
                   "code.filepath" => "./test/opentelemetry_dsl_test.exs",
                   "code.function" => "fun/1",
                   "code.lineno" => 37,
                   "code.namespace" => "OpentelemetryDSLTest.Debugging"
                 } do
                 try do
                   OpentelemetryDSL.__record_threads__()
                   OpentelemetryDSL.__record_arguments__([arg0], false)
                   result = super(arg0)
                   OpentelemetryDSL.__record_results__(result, false)
                   result
                 rescue
                   exception ->
                     OpentelemetryDSL.__record_errors__(exception, true)
                     reraise exception, __STACKTRACE__
                 end
               end
             end
             '''
    end

    test "raises when given an unknown use option" do
      msg = ~r"""
      unsupported option :foo, must be one of \[:debug\]
      """

      assert_raise CompileError, msg, fn ->
        defmodule UnknownOpt do
          use OpentelemetryDSL, foo: :bar
        end
      end
    end

    test "warns when there are no calls to trace/1 or trace_all/1" do
      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule Unused do
            use OpentelemetryDSL
          end
        end)

      assert stderr =~ """
             use OpentelemetryDSL called but no traces are defined, are you missing trace/1 or trace_all/1?
             """
    end
  end

  defmodule Impl do
    defstruct [:data]
  end

  defimpl OpentelemetryDSL.Encoder, for: Impl do
    def encode(term) do
      "##{inspect(Impl)}<data: #{inspect(term.data)}>"
    end
  end

  defmodule NoImpl do
    defstruct [:data]
  end

  defmodule Traced do
    use OpentelemetryDSL

    trace()

    def my_public_fun(arg) do
      arg
    end

    trace()

    defp my_private_fun(arg) do
      arg
    end

    def call_private_fun(arg) do
      my_private_fun(arg)
    end

    trace()

    def my_fun_with_guards(arg) when is_binary(arg) do
      String.upcase(arg)
    end

    trace()

    def my_multi_arity_fun(a, b, c) do
      {a, b, c}
    end

    trace()

    def parent do
      child()
    end

    trace()

    def child do
      :ok
    end

    trace()

    def raises do
      raise "aaaaaaah!"
    end

    trace()

    def fun_with_unused_args(a, _b) do
      a
    end

    trace()

    def fun_with_unused_default(a, _b \\ :b) do
      a
    end

    trace()

    def fun_with_source do
      :ok
    end

    trace()

    def fun_with_pattern_match(:apple) do
      :apple
    end

    trace()

    def fun_with_unnamed_unused_arg(_) do
      :ok
    end

    trace()

    def fun_with_multiple_heads(:foo) do
      :foo
    end

    trace()

    def fun_with_multiple_heads(:bar) do
      :bar
    end

    trace(attrs: [foo: :bar])

    def fun_with_custom_attrs do
      :ok
    end

    trace(kind: :internal)

    def internal_span_fun do
      :internal
    end

    trace(kind: :producer)

    def producer_span_fun do
      :producer
    end

    trace(kind: :consumer)

    def consumer_span_fun do
      :consumer
    end

    trace(kind: :client)

    def client_span_fun do
      :client
    end

    trace(kind: :server)

    def server_span_fun do
      :server
    end

    trace(record_arguments: true)

    def recorded_argument(arg) do
      arg
    end

    trace(record_arguments: true)

    def recorded_arguments(a, b, c) do
      {a, b, c}
    end

    trace(record_results: true)

    def recorded_results(fun) do
      fun.()
    end
  end

  describe "trace/1" do
    test "emits a span when the corresponding public function is invoked" do
      assert Traced.my_public_fun(:foo) == :foo
      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.my_public_fun/1")}
    end

    test "emits a span when the corresponding private function is invoked" do
      assert Traced.call_private_fun(:foo) == :foo
      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.my_private_fun/1")}
    end

    test "supports tracing functions with guards" do
      assert Traced.my_fun_with_guards("foo") == "FOO"
      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.my_fun_with_guards/1")}
    end

    test "supports tracing functions multiple arguments" do
      assert Traced.my_multi_arity_fun(:a, :b, :c) == {:a, :b, :c}
      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.my_multi_arity_fun/3")}
    end

    test "supports tracing functions with unused arguments" do
      assert Traced.fun_with_unused_args(:a, :b) == :a
      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.fun_with_unused_args/2")}
    end

    test "supports tracing functions with unused default arguments" do
      assert Traced.fun_with_unused_default(:a) == :a

      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.fun_with_unused_default/2")}
    end

    test "supports tracing functions with patterns in arguments" do
      assert Traced.fun_with_pattern_match(:apple) == :apple

      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.fun_with_pattern_match/1")}
    end

    test "supports tracing functions with an unused, unnamed argument" do
      assert Traced.fun_with_unnamed_unused_arg(:ok) == :ok

      assert_receive {:span,
                      span(name: "OpentelemetryDSLTest.Traced.fun_with_unnamed_unused_arg/1")}
    end

    test "supports tracing functions with multiple heads" do
      assert Traced.fun_with_multiple_heads(:foo) == :foo

      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.fun_with_multiple_heads/1")}

      assert Traced.fun_with_multiple_heads(:bar) == :bar

      assert_receive {:span, span(name: "OpentelemetryDSLTest.Traced.fun_with_multiple_heads/1")}
    end

    test "supports custom, static span attributes" do
      assert Traced.fun_with_custom_attrs() == :ok

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.fun_with_custom_attrs/0",
                        attributes: {:attributes, _, _, _, %{"foo" => :bar}}
                      )}
    end

    test "supports setting the :internal span kind" do
      assert Traced.internal_span_fun() == :internal

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.internal_span_fun/0",
                        kind: :internal
                      )}
    end

    test "supports setting the :producer span kind" do
      assert Traced.producer_span_fun() == :producer

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.producer_span_fun/0",
                        kind: :producer
                      )}
    end

    test "supports setting the :consumer span kind" do
      assert Traced.consumer_span_fun() == :consumer

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.consumer_span_fun/0",
                        kind: :consumer
                      )}
    end

    test "supports setting the :client span kind" do
      assert Traced.client_span_fun() == :client

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.client_span_fun/0",
                        kind: :client
                      )}
    end

    test "supports setting the :server span kind" do
      assert Traced.server_span_fun() == :server

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.server_span_fun/0",
                        kind: :server
                      )}
    end

    test "injects code dynamic span attributes" do
      assert Traced.my_public_fun(:foo) == :foo

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.my_public_fun/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _,
                           %{
                             "code.function" => "my_public_fun/1",
                             "code.namespace" => "OpentelemetryDSLTest.Traced",
                             "code.filepath" => "./test/opentelemetry_dsl_test.exs",
                             "code.lineno" => 112
                           }}
                      )}
    end

    test "links to parent span if one exists in the current ctx" do
      assert Traced.parent() == :ok

      assert_receive {:span,
                      span(name: "OpentelemetryDSLTest.Traced.parent/0", span_id: parent_id)}

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.child/0",
                        parent_span_id: ^parent_id
                      )}
    end

    test "records Integer values" do
      assert Traced.recorded_argument(1)

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"code.arguments.arg0" => 1}}
                      )}
    end

    test "records Float values" do
      assert Traced.recorded_argument(1.34359)

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"code.arguments.arg0" => 1.34359}}
                      )}
    end

    test "records BitString values" do
      assert Traced.recorded_argument("apples")

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"code.arguments.arg0" => "apples"}}
                      )}
    end

    test "records Atom values" do
      assert Traced.recorded_argument(:pi)

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"code.arguments.arg0" => :pi}}
                      )}
    end

    test "records List values" do
      assert Traced.recorded_argument(["a", "b", "c"])

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _, %{"code.arguments.arg0" => ["a", "b", "c"]}}
                      )}
    end

    test "records Tuple values" do
      assert Traced.recorded_argument({"a", "b", "c"})

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _, %{"code.arguments.arg0" => ["a", "b", "c"]}}
                      )}
    end

    test "records Map values" do
      assert Traced.recorded_argument(%{a: "a", b: "b", c: "c"})

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _,
                           %{
                             "code.arguments.arg0.a" => "a",
                             "code.arguments.arg0.b" => "b",
                             "code.arguments.arg0.c" => "c"
                           }}
                      )}
    end

    test "records Struct values that implement the protocol" do
      assert Traced.recorded_argument(%Impl{data: :data})

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _,
                           %{
                             "code.arguments.arg0" => "#OpentelemetryDSLTest.Impl<data: :data>"
                           }}
                      )}
    end

    test "records :otel_nested_list for nested Lists" do
      assert Traced.recorded_argument([["a"]])

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _, %{"code.arguments.arg0" => :otel_nested_list}}
                      )}
    end

    test "records :otel_nested_list for nested Tuples" do
      assert Traced.recorded_argument({{"a"}})

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _, %{"code.arguments.arg0" => :otel_nested_list}}
                      )}
    end

    test "records :otel_heterogeneous_list for non-homogenous Lists" do
      assert Traced.recorded_argument(["a", :b])

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _,
                           %{"code.arguments.arg0" => :otel_heterogeneous_list}}
                      )}
    end

    test "records :otel_heterogeneous_list for non-homogenous Tuples" do
      assert Traced.recorded_argument({"a", :b})

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _,
                           %{"code.arguments.arg0" => :otel_heterogeneous_list}}
                      )}
    end

    test "records :otel_no_encoder for structs with no protocol implementation" do
      assert Traced.recorded_argument(%NoImpl{data: "data"})

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_argument/1",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _, %{"code.arguments.arg0" => :otel_no_encoder}}
                      )}
    end

    test "records the result of the function invocation" do
      assert Traced.recorded_results(fn -> "a result" end) == "a result"

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.recorded_results/1",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"code.result" => "a result"}}
                      )}
    end

    test "captures, records, and reraises exceptions" do
      assert_raise RuntimeError, fn ->
        Traced.raises()
      end

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.Traced.raises/0",
                        status: {:status, :error, "aaaaaaah!"},
                        events:
                          {_, _, _, _, _,
                           [
                             {_, _, "exception",
                              {_, _, _, _,
                               %{
                                 :"exception.message" => "aaaaaaah!",
                                 :"exception.type" => "Elixir.RuntimeError"
                               }}}
                           ]}
                      )}
    end

    test "raises if multiple trace macros are defined for the same function" do
      msg = ~r"cannot define multiple traces for the same function"

      assert_raise CompileError, msg, fn ->
        defmodule MultipleTraces do
          use OpentelemetryDSL

          trace()
          trace()

          def fun, do: :ok
        end
      end
    end

    test "raises if there is no corresponding function to trace" do
      msg = ~r"a trace must be defined before a function"

      assert_raise CompileError, msg, fn ->
        defmodule NoFunction do
          use OpentelemetryDSL

          trace()
        end
      end
    end

    test "raises when given an unknown trace option" do
      msg = ~r"""
      unsupported option :foo, must be one of \[:attrs, :kind, :record_arguments, :record_results\]
      """

      assert_raise CompileError, msg, fn ->
        defmodule UnknownOpt do
          use OpentelemetryDSL

          trace(foo: :foo)

          def foo do
            :foo
          end
        end
      end
    end

    test "raises when given an unkown span kind" do
      msg = ~r"""
      option :kind must be one of \[:client, :server, :producer, :consumer, :internal\], got: :fancy
      """

      assert_raise CompileError, msg, fn ->
        defmodule UnknownKind do
          use OpentelemetryDSL

          trace(kind: :fancy)

          def fancy do
            :fancy
          end
        end
      end
    end
  end

  defmodule TraceAll do
    use OpentelemetryDSL

    trace_all(kind: :internal, attrs: [foo: :bar])

    def fun_one(arg) do
      arg
    end

    def fun_two(arg) do
      arg
    end

    def fun_raises do
      raise "boom!"
    end

    def call_private_fun do
      private_fun()
    end

    defp private_fun do
      :ok
    end
  end

  describe "trace_all/1" do
    test "traces all public functions in a module with `trace_all`" do
      assert TraceAll.fun_one(:foo) == :foo

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.TraceAll.fun_one/1",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"foo" => :bar}}
                      )}

      assert TraceAll.fun_two(:foo) == :foo

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.TraceAll.fun_two/1",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"foo" => :bar}}
                      )}

      assert_raise RuntimeError, fn -> TraceAll.fun_raises() end

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.TraceAll.fun_raises/0",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"foo" => :bar}},
                        status: {:status, :error, "boom!"},
                        events:
                          {_, _, _, _, _,
                           [
                             {_, _, "exception",
                              {_, _, _, _,
                               %{
                                 :"exception.message" => "boom!",
                                 :"exception.type" => "Elixir.RuntimeError"
                               }}}
                           ]}
                      )}

      assert TraceAll.call_private_fun() == :ok

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.TraceAll.call_private_fun/0",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"foo" => :bar}}
                      )}

      refute_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.TraceAll.private_fun/0",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"foo" => :bar}}
                      )}
    end
  end

  defmodule TraceAttrs do
    use OpentelemetryDSL

    trace_all(kind: :internal, attrs: [foo: :bar])

    def fun(string) do
      trace_attrs(dynamic: String.upcase(string))
      :ok
    end

    def fun2 do
      trace_attrs(dynamic: %Impl{data: :data})
      :ok
    end
  end

  describe "trace_attrs/1" do
    test "injects dynamic attributes into the current span" do
      assert TraceAttrs.fun("hello") == :ok

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.TraceAttrs.fun/1",
                        kind: :internal,
                        attributes: {:attributes, _, _, _, %{"foo" => :bar, "dynamic" => "HELLO"}}
                      )}
    end

    test "encodes dynamic attributes with Encoder protocol" do
      assert TraceAttrs.fun2() == :ok

      assert_receive {:span,
                      span(
                        name: "OpentelemetryDSLTest.TraceAttrs.fun2/0",
                        kind: :internal,
                        attributes:
                          {:attributes, _, _, _,
                           %{
                             "foo" => :bar,
                             "dynamic" => "#OpentelemetryDSLTest.Impl<data: :data>"
                           }}
                      )}
    end
  end
end
