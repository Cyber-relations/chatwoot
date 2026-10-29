# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User do
  let!(:user) { create(:user, otp_secret: described_class.generate_otp_secret, otp_required_for_login: true) }
  # A step ahead of real time; each travel_to lands five seconds into the step it names.
  let(:step) { (Time.current.to_i / 30) + 10 }

  def at_step(offset, &)
    travel_to(Time.zone.at(((step + offset) * 30) + 5), &)
  end

  def code_for(offset)
    user.otp.at((step + offset) * 30)
  end

  it 'accepts a code from the next step once and rejects it again inside its own step' do
    code = code_for(1)
    at_step(0) { expect(user.validate_and_consume_otp!(code)).to be(true) }
    expect(user.reload.consumed_timestep).to eq(step + 1)

    at_step(1) { expect(user.reload.validate_and_consume_otp!(code)).to be(false) }
    at_step(2) { expect(user.reload.validate_and_consume_otp!(code)).to be(false) }
  end

  # An authenticator 30 seconds ahead shows the code of the server's next step at every moment.
  it 'accepts the next unused code of a fast device in the following step and rejects the used one' do
    at_step(0) { expect(user.validate_and_consume_otp!(code_for(1))).to be(true) }
    at_step(1) do
      expect(user.reload.validate_and_consume_otp!(code_for(1))).to be(false)
      expect(user.reload.validate_and_consume_otp!(code_for(2))).to be(true)
    end
    expect(user.reload.consumed_timestep).to eq(step + 2)
  end

  # An authenticator 30 seconds behind shows the code of the server's previous step at every moment.
  it 'accepts the next unused code of a slow device in the following step and rejects the used one' do
    at_step(0) do
      expect(user.validate_and_consume_otp!(code_for(-1))).to be(true)
      expect(user.reload.validate_and_consume_otp!(code_for(-1))).to be(false)
    end
    expect(user.reload.consumed_timestep).to eq(step - 1)
    at_step(1) { expect(user.reload.validate_and_consume_otp!(code_for(0))).to be(true) }
    expect(user.reload.consumed_timestep).to eq(step)
  end

  it 'accepts each code once and never a code at or before the last accepted one' do
    at_step(0) do
      expect(user.validate_and_consume_otp!(code_for(0))).to be(true)
      expect(user.reload.validate_and_consume_otp!(code_for(0))).to be(false)
      expect(user.reload.validate_and_consume_otp!(code_for(-1))).to be(false)
      expect(user.reload.validate_and_consume_otp!(code_for(1))).to be(true)
      expect(user.reload.validate_and_consume_otp!(code_for(1))).to be(false)
      expect(user.reload.validate_and_consume_otp!(code_for(0))).to be(false)
    end
    expect(user.reload.consumed_timestep).to eq(step + 1)
  end

  it 'rejects wrong, blank and stale codes without recording a step' do
    window = (-1..1).map { |offset| code_for(offset) }
    wrong = %w[000000 111111 222222 333333].find { |candidate| window.exclude?(candidate) }
    at_step(0) do
      expect(user.validate_and_consume_otp!(wrong)).to be(false)
      expect(user.validate_and_consume_otp!('')).to be(false)
      expect(user.validate_and_consume_otp!(code_for(-2))).to be(false)
    end
    expect(user.reload.consumed_timestep).to be_nil
  end
end
