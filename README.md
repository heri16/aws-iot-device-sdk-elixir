# AWS IoT SDK for Elixir

The aws-iot-device-sdk-elixir package allows developers to write [Elixir](http://elixir-lang.org) applications which access the [AWS IoT Platform](https://aws.amazon.com/iot/) via [MQTT](http://docs.aws.amazon.com/iot/latest/developerguide/protocols.html).  It can be used in standard [Elixir](http://elixir-lang.org) environments as well as in [Nerves](http://nerves-project.org) embedded applications.

Closely follows the logic from the official nodejs library, with minor deviations to adapt to Elixir Coding Conventions:
https://github.com/aws/aws-iot-device-sdk-js/blob/master/thing/index.js

* [Overview](#overview)
* [Installation](#install)
* [Configuration](#configuration)
* [Basic Usage](#basic-usage)
* [Application Usage](#otp-usage)
* [Troubleshooting](#troubleshooting)
* [License](#license)
* [Support](#support)


<a name="overview"></a>
## Overview
This document provides instructions on how to install and configure the AWS 
IoT device SDK for Elixir, and includes examples demonstrating use of the
SDK APIs.

#### MQTT Connection
This package is built on top of [emqttc](https://github.com/emqtt/emqttc) and provides two modules: 'Aws.Iot.Device'
and 'Aws.Iot.ThingShadow'.  The 'Device' module wraps [emqttc](https://github.com/emqtt/emqttc) to provide a
secure connection to the AWS IoT platform and expose the [emqttc](https://github.com/emqtt/emqttc) API upward.  It provides features to simplify handling of intermittent connections, including progressive backoff retries, automatic re-subscription upon connection, and queued offline publishing.

#### Thing Shadows
The 'Aws.Iot.ThingShadow' module implements additional functionality for accessing Thing Shadows via the AWS IoT
API; the ThingShadow module allows devices to update, be notified of changes to,
get the current state of, or delete Thing Shadows from AWS IoT.  Thing
Shadows allow applications and devices to synchronize their state on the AWS IoT platform.
For example, a remote device can update its Thing Shadow in AWS IoT, allowing
a user to view the device's last reported state via a mobile app.  The user
can also update the device's Thing Shadow in AWS IoT and the remote device 
will synchronize with the new state.  The 'ThingShadow' module supports multiple 
Thing Shadows per mqtt connection and allows pass-through of non-Thing-Shadow
topics and mqtt events.


<a name="install"></a>
## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add aws_iot to your list of dependencies in `mix.exs`:

        def deps do
          [{:aws_iot, "~> 0.0.1"}]
        end

  2. Ensure aws_iot is started before your application:

        def application do
          [applications: [:aws_iot]]
        end


<a name="configuration"></a>
## Configuration

The Mix configuration in config/config.exs should look like this:

```elixir
config :aws_iot, Aws.Iot.ShadowThing.Client,
  host: "xxxxxxxxx.iot.<region>.amazonaws.com",
  port: 8883,
  client_id: "xxxxxxx",
  ca_cert: "config/certs/root-CA.crt",
  client_cert: "config/certs/xxxxxxxxxx-certificate.pem.crt",
  private_key: "config/certs/xxxxxxxxxx-private.pem.key",
  mqttc_opts: []
```


<a name="basic-usage"></a>
## Basic Usage

You can try out the below in IEx:

```elixir
alias Aws.Iot.ThingShadow

# Initializes a new ThingShadow.Client process
# Events from this client will be forwarded to self()
{:ok, client} = ThingShadow.init_client([cast: self()])

# Register interest in a thing (required)
ThingShadow.Client.register(client, "aws-iot-thing-name")

# Get shadow state for a thing 
ThingShadow.Client.get(client, "aws-iot-thing-name")

# See ThingShadow.Client events sent to self() via MyThing.PubSub
Process.info(self)[:messages]
```


<a name="otp-usage"></a>
## OTP Application Usage

  1. Add event bus to the supervisor of your application module.

  ```elixir
    def start(_type, _args) do
      ...
      children = [
        ...,
        supervisor(Phoenix.PubSub.PG2, [MyThings.PubSub, []])
      ]
      ...
    end
  ```

  2. Create a GenServer module that will subscribe to the event bus.

  ```elixir
    alias Aws.Iot.ThingShadow

    def init(_args) do
      Phoenix.PubSub.subscribe(MyThings.PubSub, "thing_shadow_event")

      {:ok, client} = ThingShadow.init_client([
          broadcast: {MyThings.PubSub, "thing_shadow_event"}
        ])

      # If we are only reporting state from an IoT Device, 
      # then versioning and persistent_subscribe is not required.
      thing_opts = [qos: 1, enable_versioning: false, persistent_subscribe: false]
      ThingShadow.Client.register(client, "aws-iot-thing-name", thing_opts)

      {:ok, %{iot_client: client, client_token_op: %{}}}
    end
  ```

  3. Add `GenServer.handle_info/2` callbacks to GenServer for event handling.

  ```elixir
    def handle_info({:connect, client}, state) do
      # Note: ThingShadow.Client will handle resubscribe to topics on reconnection.

      # According to AWS docs, an IoT device should report 
      # its shadow_state on reconnection
      shadow_state_report = %{state: %{reported: %{ 
        "led_on" => false 
      }}}
      {:ok, client_token} = ThingShadow.Client.update(client, 
        "aws-iot-thing-name", shadow_state_report)
      state = put_client_token(client_token, :update, state)

      {:noreply, state}
    end

    def handle_info({:delta, "aws-iot-thing-name", shadow_state}, state) do
      IO.inspect(shadow_state)

      # According to AWS docs, an IoT device should act on any delta
      desired_state_of_led_on = shadow_state["state"]["led_on"]
      case desired_state_of_led_on do
        true -> IO.puts "Led will be turned on"
        false -> IO.puts "Led will be turned off"
      end

      {:noreply, state}
    end

    def handle_info({:status, "aws-iot-thing-name", :accepted, client_token, shadow_state}, state = %{client_token_op: client_token_op}) do
      case client_token_op[client_token] do
        :get -> IO.inspect(shadow_state)
        :update -> IO.inspect(shadow_state)
        :delete -> IO.inspect(shadow_state)
        nil -> IO.puts "Missing token"
      end

      state = remove_client_token(client_token, state)
      {:noreply, state}
    end

    def handle_info({:status, "aws-iot-thing-name", :rejected, client_token, shadow_state}, state) do
      IO.inspect(shadow_state)
      state = remove_client_token(client_token, state)
      {:noreply, state}
    end

    def handle_info({:timeout, "aws-iot-thing-name", client_token}, state) do
      IO.inspect(client_token)
      state = remove_client_token(client_token, state)
      {:noreply, state}
    end

    defp put_client_token(client_token, op, state = %{client_token_op: client_token_op}) do
      client_token_op = Map.put(client_token_op, client_token, op)
      %{state | client_token_op: client_token_op}
    end

    defp remove_client_token(client_token, state = %{client_token_op: client_token_op}) do
      client_token_op = Map.delete(client_token_op, client_token)
      %{state | client_token_op: client_token_op}
    end
  ```

  4. Use `ThingShadow.Client.publish/3` to trigger AWS IoT Rules.

    Try creating a simple rule to forward messages to AWS SNS, which sends alert notifications via Email or Cellular SMS Messages.

    Read more:
    - [AWS IoT Rules](http://docs.aws.amazon.com/iot/latest/developerguide/iot-rules.html)
    - [AWS IoT Rule Tutorials](http://docs.aws.amazon.com/iot/latest/developerguide/iot-rules-tutorial.html)
    - [AWS SNS Sending SMS](http://docs.aws.amazon.com/sns/latest/dg/SMSMessages.html)

    **Important**: Do not use the publish function to communicate with any IoT device, as MQTT messages are lost when the device is disconnected from the broker.


<a name="troubleshooting"></a>
## Troubleshooting

If you have problems connecting to the AWS IoT Platform when using this SDK, there are a few things to check:

* _Region Mismatch_:  If you didn't create your 
certificate in the default region ('us-east-1'), you'll need to specify 
the region (e.g., 'us-west-2') that you created your certificate in. 
* _Duplicate Client IDs_:  Within your AWS account, the AWS IoT platform
will only allow one connection per client ID.  
If you are using a [Mix configuration file](#configuration), you'll
need to explictly specify client IDs.


<a name="license"></a>
## License

This SDK is distributed under the [Apache License, Version 2.0](http://www.apache.org/licenses/LICENSE-2.0), see LICENSE.txt and NOTICE.txt for more information.


<a name="suport"></a>
## Support
If you have technical questions about AWS IoT Device SDK, use the [Slack Nerves Channel](https://elixir-lang.slack.com/archives/nerves).
For any other questions on AWS IoT, contact [AWS Support](https://aws.amazon.com/contact-us).