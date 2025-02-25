defmodule TelemetryMetricsStatsdTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import TelemetryMetricsStatsd.Test.{Helpers, WaitUntil}

  test "counter metric is reported as StatsD counter with 1 as a value" do
    {socket, port} = given_udp_port_opened()
    counter = given_counter("http.requests", event_name: "http.request")

    start_reporter(metrics: [counter], port: port)

    :telemetry.execute([:http, :request], %{latency: 211})
    :telemetry.execute([:http, :request], %{latency: 200})
    :telemetry.execute([:http, :request], %{latency: 198})

    assert_reported(socket, "http.requests:1|c")
    assert_reported(socket, "http.requests:1|c")
    assert_reported(socket, "http.requests:1|c")
  end

  test "sum metric is reported as StatsD gauge with +n value" do
    {socket, port} = given_udp_port_opened()
    sum = given_sum("http.request.payload_size")

    start_reporter(metrics: [sum], port: port)

    :telemetry.execute([:http, :request], %{payload_size: 2001})
    :telemetry.execute([:http, :request], %{payload_size: 1585})
    :telemetry.execute([:http, :request], %{payload_size: 1872})

    assert_reported(socket, "http.request.payload_size:+2001|g")
    assert_reported(socket, "http.request.payload_size:+1585|g")
    assert_reported(socket, "http.request.payload_size:+1872|g")
  end

  test "last value metric is reported as StatsD gauge with absolute value" do
    {socket, port} = given_udp_port_opened()
    last_value = given_last_value("vm.memory.total")

    start_reporter(metrics: [last_value], port: port)

    :telemetry.execute([:vm, :memory], %{total: 2001})
    :telemetry.execute([:vm, :memory], %{total: 1585})
    :telemetry.execute([:vm, :memory], %{total: 1872})

    assert_reported(socket, "vm.memory.total:2001|g")
    assert_reported(socket, "vm.memory.total:1585|g")
    assert_reported(socket, "vm.memory.total:1872|g")
  end

  test "summary metric is reported as StastD timer" do
    {socket, port} = given_udp_port_opened()
    summary = given_summary("http.request.latency")

    start_reporter(metrics: [summary], port: port)

    :telemetry.execute([:http, :request], %{latency: 172})
    :telemetry.execute([:http, :request], %{latency: 200})
    :telemetry.execute([:http, :request], %{latency: 198})

    assert_reported(socket, "http.request.latency:172|ms")
    assert_reported(socket, "http.request.latency:200|ms")
    assert_reported(socket, "http.request.latency:198|ms")
  end

  test "distribution metric is reported as StastD timer" do
    {socket, port} = given_udp_port_opened()

    dist =
      given_distribution(
        "http.request.latency",
        buckets: [0, 100, 200, 300]
      )

    start_reporter(metrics: [dist], port: port)

    :telemetry.execute([:http, :request], %{latency: 172})
    :telemetry.execute([:http, :request], %{latency: 200})
    :telemetry.execute([:http, :request], %{latency: 198})

    assert_reported(socket, "http.request.latency:172|ms")
    assert_reported(socket, "http.request.latency:200|ms")
    assert_reported(socket, "http.request.latency:198|ms")
  end

  test "standard formatter can be provided explicitly" do
    {socket, port} = given_udp_port_opened()

    counter =
      given_counter(
        "http.requests",
        event_name: "http.request",
        tags: [:env, :method, :status]
      )

    start_reporter(
      metrics: [counter],
      port: port,
      formatter: :standard,
      global_tags: [env: "test"]
    )

    :telemetry.execute([:http, :request], %{latency: 172}, %{method: "GET", status: 200})
    :telemetry.execute([:http, :request], %{latency: 172}, %{env: "dev", method: "GET", status: 200})

    assert_reported(socket, "http.requests.test.GET.200:1|c")
    assert_reported(socket, "http.requests.dev.GET.200:1|c")
  end

  test "DataDog formatter can be used" do
    {socket, port} = given_udp_port_opened()

    counter =
      given_counter(
        "http.requests",
        event_name: "http.request",
        tags: [:env, :method, :status]
      )

    start_reporter(
      metrics: [counter],
      port: port,
      formatter: :datadog,
      global_tags: [env: "test"]
    )

    :telemetry.execute([:http, :request], %{latency: 172}, %{method: "GET", status: 200})
    :telemetry.execute([:http, :request], %{latency: 200}, %{method: "POST", status: 201})
    :telemetry.execute([:http, :request], %{latency: 198}, %{method: "GET", status: 404})
    :telemetry.execute([:http, :request], %{latency: 198}, %{env: "dev", method: "GET", status: 404})

    assert_reported(socket, "http.requests:1|c|#env:test,method:GET,status:200")
    assert_reported(socket, "http.requests:1|c|#env:test,method:POST,status:201")
    assert_reported(socket, "http.requests:1|c|#env:test,method:GET,status:404")
    assert_reported(socket, "http.requests:1|c|#env:dev,method:GET,status:404")
  end

  test "it fails to start with invalid formatter" do
    counter = given_counter("http.request.count")

    assert_raise ArgumentError, fn ->
      start_reporter(metrics: [counter], formatter: :my_formatter)
    end
  end

  test "measurement function is taken into account when getting the value for the metric" do
    {socket, port} = given_udp_port_opened()
    last_value = given_last_value("vm.memory.total", measurement: fn m -> m.total * 2 end)

    start_reporter(metrics: [last_value], port: port)

    :telemetry.execute([:vm, :memory], %{total: 2001})
    :telemetry.execute([:vm, :memory], %{total: 1585})
    :telemetry.execute([:vm, :memory], %{total: 1872})

    assert_reported(socket, "vm.memory.total:4002|g")
    assert_reported(socket, "vm.memory.total:3170|g")
    assert_reported(socket, "vm.memory.total:3744|g")
  end

  test "there can be multiple metrics derived from the same event" do
    {socket, port} = given_udp_port_opened()

    dist =
      given_distribution(
        "http.request.latency",
        buckets: [0, 100, 200, 300]
      )

    sum = given_sum("http.request.payload_size")

    start_reporter(metrics: [dist, sum], port: port)

    :telemetry.execute([:http, :request], %{latency: 172, payload_size: 121})
    :telemetry.execute([:http, :request], %{latency: 200, payload_size: 64})
    :telemetry.execute([:http, :request], %{latency: 198, payload_size: 1021})

    assert_reported(
      socket,
      "http.request.latency:172|ms\n" <> "http.request.payload_size:+121|g"
    )

    assert_reported(
      socket,
      "http.request.latency:200|ms\n" <> "http.request.payload_size:+64|g"
    )

    assert_reported(
      socket,
      "http.request.latency:198|ms\n" <> "http.request.payload_size:+1021|g"
    )
  end

  test "too big payloads produced by single event are broken into multiple UDP datagrams" do
    {socket, port} = given_udp_port_opened()

    metrics = [
      given_counter("first.counter", event_name: "http.request"),
      given_counter("second.counter", event_name: "http.request"),
      given_counter("third.counter", event_name: "http.request"),
      given_counter("fourth.counter", event_name: "http.request")
    ]

    start_reporter(metrics: metrics, port: port, mtu: 40)

    :telemetry.execute([:http, :request], %{latency: 172, payload_size: 121})

    assert_reported(
      socket,
      "first.counter:1|c\n" <> "second.counter:1|c"
    )

    assert_reported(
      socket,
      "third.counter:1|c\n" <> "fourth.counter:1|c"
    )
  end

  describe "UDP error handling" do
    test "notifying a UDP error logs an error" do
      reporter = start_reporter(metrics: [])
      udp = TelemetryMetricsStatsd.get_udp(reporter)

      assert capture_log(fn ->
               TelemetryMetricsStatsd.udp_error(reporter, udp, :closed)
               # Can we do better here? We could use `call` instead of `cast` for reporting socket
               # errors.
               Process.sleep(100)
             end) =~ ~r/\[error\] Failed to publish metrics over UDP: :closed/
    end

    test "notifying a UDP error for the same socket multiple times generates only one log" do
      reporter = start_reporter(metrics: [])
      udp = TelemetryMetricsStatsd.get_udp(reporter)

      assert capture_log(fn ->
               TelemetryMetricsStatsd.udp_error(reporter, udp, :closed)
               Process.sleep(100)
             end) =~ ~r/\[error\] Failed to publish metrics over UDP: :closed/

      assert capture_log(fn ->
               TelemetryMetricsStatsd.udp_error(reporter, udp, :closed)
               Process.sleep(100)
             end) == ""
    end

    @tag :capture_log
    test "notifying a UDP error and fetching a socket returns a new socket" do
      reporter = start_reporter(metrics: [])
      udp = TelemetryMetricsStatsd.get_udp(reporter)

      TelemetryMetricsStatsd.udp_error(reporter, udp, :closed)
      new_udp = TelemetryMetricsStatsd.get_udp(reporter)

      assert new_udp != udp
    end
  end

  test "published metrics are prefixed with the provided prefix" do
    {socket, port} = given_udp_port_opened()

    metrics = [
      given_counter("http.request.count"),
      given_distribution("http.request.latency", buckets: [0, 100, 200]),
      given_last_value("http.request.current_memory"),
      given_sum("http.request.payload_size")
    ]

    start_reporter(metrics: metrics, port: port, prefix: "myapp")

    :telemetry.execute([:http, :request], %{latency: 200, current_memory: 200, payload_size: 200})

    assert_reported(
      socket,
      "myapp.http.request.count:1|c\n" <>
        "myapp.http.request.latency:200|ms\n" <>
        "myapp.http.request.current_memory:200|g\n" <> "myapp.http.request.payload_size:+200|g"
    )
  end

  @tag :capture_log
  test "metrics are not sent when reporter receives an exit signal" do
    {socket, port} = given_udp_port_opened()

    reporter =
      start_reporter(
        metrics: [
          given_counter("first.event.count"),
          given_counter("second.event.count")
        ],
        port: port
      )

    Process.unlink(reporter)

    # Make sure that event handlers are detached even if non-parent process sends an exit signal.
    spawn(fn -> Process.exit(reporter, :some_reason) end)
    wait_until(fn -> not Process.alive?(reporter) end)

    assert :telemetry.list_handlers([:first, :event]) == []
    assert :telemetry.list_handlers([:second, :event]) == []

    :telemetry.execute([:first, :event], %{})
    :telemetry.execute([:second, :event], %{})

    refute_reported(socket)
  end

  test "metrics are not sent when reporter is shut down by its supervisor" do
    {socket, port} = given_udp_port_opened()

    metrics = [
      given_counter("first.event.count"),
      given_counter("second.event.count")
    ]

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          Supervisor.Spec.worker(TelemetryMetricsStatsd, [[metrics: metrics, port: port]])
        ],
        strategy: :one_for_one
      )

    Process.unlink(supervisor)

    Supervisor.stop(supervisor, :shutdown)

    assert :telemetry.list_handlers([:first, :event]) == []
    assert :telemetry.list_handlers([:second, :event]) == []

    :telemetry.execute([:first, :event], %{})
    :telemetry.execute([:second, :event], %{})

    refute_reported(socket)
  end

  test "non-number measurement prevents the metric from being updated" do
    {socket, port} = given_udp_port_opened()
    sum = given_sum("my.metric", event_name: [:my, :event], measurement: :non_number)

    start_reporter(metrics: [sum], port: port)

    :telemetry.execute([:my, :event], %{non_number: :not_a_number})

    refute_reported(socket)
  end

  defp given_udp_port_opened() do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  defp start_reporter(options) do
    {:ok, pid} = TelemetryMetricsStatsd.start_link(options)
    pid
  end

  defp assert_reported(socket, expected_payload) do
    expected_size = byte_size(expected_payload)
    {:ok, {_host, _port, payload}} = :gen_udp.recv(socket, expected_size)
    assert payload == expected_payload
  end

  defp refute_reported(socket) do
    assert {:error, :timeout} = :gen_udp.recv(socket, 0, 1000)
  end
end
