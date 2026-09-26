# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # Checkout Session 作成用の form パラメータ。日本向け固定値をここに集約する。
    module SessionForm
      module_function

      # 新規店舗の Checkout は購読の明細 1 件だけ。開通(Growth::OpeningTerms)は割引 0 と
      # 「Session 小計 = 購読明細の小計」を要求するため、割引コードも任意オプションも載せない。
      # 既存店舗のアプリ内購入・追加パックは別の form(Growth::PurchaseForm / PackForm)。
      def build(input)
        locale_and_country
          .merge(identity(input))
          .merge(custom_fields)
          .merge(terms_consent(input[:consent], submit_message: input.fetch(:submit_message)))
      end

      # 規約同意欄はアプリ内同意の有無に関係なく必須(fail-closed)。Stripe Dashboard の
      # Terms of service URL が未登録だと Session 作成自体が失敗する。
      def terms_consent(consent, submit_message:)
        values = {
          'consent_collection[terms_of_service]' => 'required',
          'custom_text[terms_of_service_acceptance][message]' => LegalTerms::TOS_MESSAGE,
          'custom_text[submit][message]' => submit_message
        }
        LegalTerms.metadata(consent).each do |key, value|
          values["metadata[#{key}]"] = value
          values["subscription_data[metadata][#{key}]"] = value
        end
        values
      end

      def locale_and_country
        {
          'mode' => 'subscription',
          'locale' => Catalog::LOCALE,
          'currency' => Catalog::CURRENCY,
          'billing_address_collection' => 'required',
          'adaptive_pricing[enabled]' => 'false',
          'automatic_tax[enabled]' => 'true',
          'tax_id_collection[enabled]' => 'true',
          'allow_promotion_codes' => 'false'
        }
      end

      def identity(input)
        plan = input.fetch(:plan)
        cycle = input.fetch(:cycle)
        {
          'customer' => input.fetch(:customer_id),
          'customer_update[address]' => 'auto',
          'customer_update[name]' => 'auto',
          'metadata[toybaco_plan]' => plan,
          'metadata[toybaco_cycle]' => cycle,
          'metadata[toybaco_plan_version]' => input.fetch(:version),
          'metadata[toybaco_reference_price_id]' => input.fetch(:price).fetch('id'),
          'subscription_data[metadata][toybaco_plan]' => plan,
          'subscription_data[metadata][toybaco_cycle]' => cycle,
          'subscription_data[metadata][toybaco_plan_version]' => input.fetch(:version),
          'subscription_data[metadata][toybaco_reference_price_id]' => input.fetch(:price).fetch('id'),
          'success_url' => input.fetch(:success_url),
          'cancel_url' => input.fetch(:cancel_url)
        }.merge(LineItem.subscription(input))
      end

      def custom_fields
        fields = company_field.merge(industry_field)
        Catalog::INDUSTRIES.each_with_index do |(value, label), index|
          fields["custom_fields[1][dropdown][options][#{index}][label]"] = label
          fields["custom_fields[1][dropdown][options][#{index}][value]"] = value
        end
        fields
      end

      def company_field
        {
          'custom_fields[0][key]' => 'company',
          'custom_fields[0][label][type]' => 'custom',
          'custom_fields[0][label][custom]' => '会社名・店舗名',
          'custom_fields[0][type]' => 'text',
          'custom_fields[0][optional]' => 'false'
        }
      end

      def industry_field
        {
          'custom_fields[1][key]' => 'industry',
          'custom_fields[1][label][type]' => 'custom',
          'custom_fields[1][label][custom]' => '業種(該当する業種は初期設定パックを適用します)',
          'custom_fields[1][type]' => 'dropdown',
          'custom_fields[1][optional]' => 'false'
        }
      end
    end
  end
end
