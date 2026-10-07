# frozen_string_literal: true

# super_adminの「設定」(installation_config)を更新すると、request parameterの
# installation_config[value]がそのままログへ出る。HCAPTCHA_SERVER_KEYのような秘密の値も
# 平文で残るため、値だけを[FILTERED]にする。どの設定を変えたかを追えるよう、設定名
# (installation_config[name])は隠さない。
Rails.application.config.filter_parameters += ['installation_config.value']
