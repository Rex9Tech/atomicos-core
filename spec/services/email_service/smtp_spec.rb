require "rails_helper"

RSpec.describe EmailService::Smtp do
  before do
    stub_const("AppConfig::SMTP_ADDRESS", "atomicos-postfix")
    stub_const("AppConfig::SMTP_PORT", 25)
    stub_const("AppConfig::FROM_EMAIL", "support@atomicos.io")
    ActionMailer::Base.deliveries.clear
  end

  subject(:provider) { described_class.new }

  it "sends a transactional email through ActionMailer" do
    provider.send_email(to: "user@example.com", subject: "Welcome", body: "<p>Hello</p>")

    expect(ActionMailer::Base.deliveries.size).to eq(1)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([ "user@example.com" ])
    expect(mail.from).to eq([ "support@atomicos.io" ])
    expect(mail.subject).to eq("Welcome")
    expect(mail.body.to_s).to include("Hello")
  end

  it "renders a symbolic template id into the master layout" do
    provider.send_template(
      to: "user@example.com",
      template_id: "email_confirmation",
      template_data: { code: "123456", email: "user@example.com" }
    )

    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq("Confirm your RexOne email")
    expect(mail.body.to_s).to include("123456")
  end

  it "is disabled when SMTP is not configured" do
    stub_const("AppConfig::SMTP_ADDRESS", "")

    expect(described_class.new.send_email(to: "user@example.com", subject: "Hi", body: "Body")).to eq("disabled" => true)
  end

  it "wraps delivery errors without exposing internals to callers" do
    allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_now).and_raise(StandardError, "boom")

    expect do
      provider.send_email(to: "user@example.com", subject: "Hi", body: "Body")
    end.to raise_error(EmailService::Error, /Failed to send email/)
  end
end
