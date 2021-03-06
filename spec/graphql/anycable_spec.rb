# frozen_string_literal: true

RSpec.describe GraphQL::AnyCable do
  subject do
    AnycableSchema.execute(
      query: query,
      context: { channel: channel, subscription_id: subscription_id },
      variables: {},
      operation_name: "SomeSubscription",
    )
  end

  let(:query) do
    <<~GRAPHQL
      subscription SomeSubscription { productUpdated { id } }
    GRAPHQL
  end

  let(:expected_result) do
    <<~JSON.strip
      {"result":{"data":{"productUpdated":{"id":"1"}}},"more":true}
    JSON
  end

  let(:channel) do
    double
  end

  let(:anycable) { AnyCable.broadcast_adapter }

  let(:subscription_id) do
    "some-truly-random-number"
  end

  before do
    allow(channel).to receive(:stream_from)
    allow(channel).to receive(:params).and_return("channelId" => "ohmycables")
    allow(anycable).to receive(:broadcast)
  end

  it "subscribes channel to stream updates from GraphQL subscription" do
    subject
    expect(channel).to have_received(:stream_from).with("graphql-subscription:#{subscription_id}")
  end

  it "broadcasts message when event is being triggered" do
    subject
    AnycableSchema.subscriptions.trigger(:product_updated, {}, { id: 1, title: "foo" })
    expect(anycable).to have_received(:broadcast).with("graphql-subscription:#{subscription_id}", expected_result)
  end

  context "with multiple subscriptions in one query" do
    let(:query) do
      <<~GRAPHQL
        subscription SomeSubscription {
          productCreated { id title }
          productUpdated { id }
        }
      GRAPHQL
    end

    context "triggering update event" do
      it "broadcasts message only for update event" do
        subject
        AnycableSchema.subscriptions.trigger(:product_updated, {}, { id: 1, title: "foo" })
        expect(anycable).to have_received(:broadcast).with("graphql-subscription:#{subscription_id}", expected_result)
      end
    end

    context "triggering create event" do
      let(:expected_result) do
        <<~JSON.strip
          {"result":{"data":{"productCreated":{"id":"1","title":"Gravizapa"}}},"more":true}
        JSON
      end

      it "broadcasts message only for create event" do
        subject
        AnycableSchema.subscriptions.trigger(:product_created, {}, { id: 1, title: "Gravizapa" })

        expect(anycable).to have_received(:broadcast).with("graphql-subscription:#{subscription_id}", expected_result)
      end
    end
  end
end
