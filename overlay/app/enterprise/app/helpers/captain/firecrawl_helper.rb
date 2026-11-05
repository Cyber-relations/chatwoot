# frozen_string_literal: true

module Captain::FirecrawlHelper
  def generate_firecrawl_token(assistant_id, account_id)
    Toybaco::Security::FirecrawlToken.generate(Firecrawl::Configuration.api_key, assistant_id, account_id)
  end
end
