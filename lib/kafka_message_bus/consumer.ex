defmodule KafkaMessageBus.Consumer do
  require Logger
  @processor_config Application.get_env(:kafka_message_bus, :consumers)
  @retry_strategy Application.get_env(:kafka_message_bus, :retry_strategy)

  def handle_messages(messages) do
    Logger.debug fn -> "Got #{Enum.count(messages)} messages" end

    for message <- messages do
      message.value
      |> Poison.decode()
      |> process_message(message)
    end
    :ok
  end

  defp process_message({:ok, value}, message) do
    Logger.metadata(request_id: value["request_id"])
    Logger.debug fn -> "Got message: #{message.topic}/#{message.partition} -> #{message.key}: #{inspect value}" end

    @processor_config
    |> Enum.each(&execute_message(message, value, &1))
  end

  defp process_message({:error, _}, %{topic: topic, value: value}) do
    Logger.error("Failed to parse message #{value} in topic: #{inspect topic}")
  end

  defp execute_message(%{topic: topic}, data = %{resource: resource}, {topic, resource, message_processor}) do
    try do
      message_processor.process(data)
    catch
      _ -> enqueue_message_retry(data, message_processor)
    end
  end

  def enqueue_message_retry(data, message_processor) when @retry_strategy == :exq do
    Exq.enqueue(Exq, "consume_queue", KafkaMessageBus.Consumer, [data, message_processor])
  end

  def enqueue_message_retry(data, message_processor) do
    Logger.warn(fn ->
      "Will not retry message with key: #{data.key} and value: #{data.value}"
    end)
  end

  #this is the function that is run by Exq when retrying the message processing
  def perform(data, message_processor) do
    Logger.debug(fn ->
      "Retrying message with action: #{data.action} and value: #{data.value}"
    end)
    message_processor.process(data)
  end

  defp execute_message(_, _, _), do: :ok
end
