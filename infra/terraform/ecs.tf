resource "aws_ecs_cluster" "main" {
  name = local.project
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.project}"
  retention_in_days = 30
  tags              = local.tags
}

# --- IAM ---

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# 実行ロール: イメージpull・ログ・シークレット取得
resource "aws_iam_role" "execution" {
  name               = "${local.project}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "read-app-secrets"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      # toybaco/postiz も読む: トイバコID の合言葉と、投稿画面側へ会社・利用者を
      # 作るための接続情報がここにある
      Resource = [
        aws_secretsmanager_secret.app.arn,
        aws_secretsmanager_secret.postiz.arn,
      ]
    }]
  })
}

# タスクロール: アプリからのS3アクセス
resource "aws_iam_role" "task" {
  name               = "${local.project}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "task_s3" {
  name = "app-storage"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.storage.arn,
        "${aws_s3_bucket.storage.arn}/*",
        aws_s3_bucket.inbound_email.arn,
        "${aws_s3_bucket.inbound_email.arn}/*",
      ]
    }]
  })
}

# --- 共通コンテナ設定 ---

locals {
  app_environment = [
    { name = "RAILS_ENV", value = "production" },
    { name = "INSTALLATION_ENV", value = "docker" },
    { name = "RAILS_LOG_TO_STDOUT", value = "true" },
    # Rails session/return cookieを常にSecureにしHSTSをapplication側でも返す。
    # Cloudflare側もmax-age=15552000・includeSubDomains・preload offで別途固定する。
    { name = "FORCE_SSL", value = "true" },
    { name = "FRONTEND_URL", value = "https://${local.app_fqdn}" },
    { name = "TOYBACO_DEPLOYMENT_ENVIRONMENT", value = var.deployment_environment },
    { name = "TOYBACO_STRIPE_MODE", value = local.is_production ? "live" : "test" },
    { name = "DEFAULT_LOCALE", value = "ja" },
    { name = "TZ", value = "Asia/Tokyo" },
    { name = "ENABLE_ACCOUNT_SIGNUP", value = "false" },
    # CE-only 運用。EE の日次ジョブ(ReconcilePlanConfigService)が community プランの
    # ブランド設定を Chatwoot デフォルトへ強制リセットするため、EE コードを無効化する
    { name = "DISABLE_ENTERPRISE", value = "true" },
    { name = "INSTALLATION_NAME", value = "トイバコ" },
    { name = "BRAND_NAME", value = "トイバコ" },
    { name = "BRAND_URL", value = "https://toybaco.jp" },
    { name = "WIDGET_BRAND_URL", value = "https://toybaco.jp" },
    { name = "LOGO", value = "/brand-assets/toybaco-logo-c4.png" },
    { name = "LOGO_DARK", value = "/brand-assets/toybaco-logo-c4-dark.png" },
    { name = "LOGO_THUMBNAIL", value = "/brand-assets/toybaco-mark-c4.png" },
    { name = "POSTGRES_HOST", value = aws_db_instance.main.address },
    { name = "POSTGRES_DATABASE", value = "chatwoot" },
    { name = "POSTGRES_USERNAME", value = "chatwoot" },
    { name = "REDIS_URL", value = "redis://${aws_elasticache_cluster.main.cache_nodes[0].address}:6379" },
    { name = "ACTIVE_STORAGE_SERVICE", value = "amazon" },
    { name = "S3_BUCKET_NAME", value = aws_s3_bucket.storage.bucket },
    { name = "AWS_REGION", value = "ap-northeast-1" },
    # システムメール送信(SES SMTP)。招待・パスワードリセット等のトランザクショナルのみ
    { name = "SMTP_ADDRESS", value = "email-smtp.ap-northeast-1.amazonaws.com" },
    { name = "SMTP_PORT", value = "587" },
    { name = "SMTP_DOMAIN", value = local.domain },
    { name = "SMTP_AUTHENTICATION", value = "login" },
    { name = "SMTP_ENABLE_STARTTLS_AUTO", value = "true" },
    { name = "MAILER_SENDER_EMAIL", value = "トイバコ <no-reply@${local.domain}>" },
    # 受信メール(Chatwoot Channel::Email + ActionMailbox SES ingress)。
    # MX/ルールセットが未整備ならアプリ側が受信箱を作らず fail-closed する。
    { name = "MAILER_INBOUND_EMAIL_DOMAIN", value = local.inbound_email_domain },
    { name = "RAILS_INBOUND_EMAIL_SERVICE", value = "ses" },
    { name = "ACTION_MAILBOX_SES_SNS_TOPIC", value = aws_sns_topic.inbound_email.arn },
    { name = "TOYBACO_INBOUND_EMAIL_MX", value = local.inbound_email_mx_host },
    { name = "TOYBACO_INBOUND_EMAIL_REGION", value = var.aws_region },
    { name = "TOYBACO_INBOUND_EMAIL_BUCKET", value = aws_s3_bucket.inbound_email.bucket },

    # トイバコID: 受信箱のログインで投稿画面にも入れるようにする。
    # 設定が無いうちは機能ごと止まっているので、受信箱の動作には影響しない。
    { name = "TOYBACO_OIDC_CLIENT_ID", value = "toybaco-postiz" },
    { name = "TOYBACO_OIDC_REDIRECT_URIS", value = "https://${local.post_fqdn}/settings" },
    { name = "TOYBACO_OIDC_ISSUER", value = "https://${local.app_fqdn}" },
    { name = "TOYBACO_OIDC_COOKIE_DOMAIN", value = ".${local.domain}" },
    { name = "TOYBACO_POST_URL", value = "https://${local.post_fqdn}" },
    # 参照する2つのAWSCURRENTが変わればrails/sidekiq/migrateも新revisionへして再起動する。
    # version IDは非機密であり、secret本文をtask definitionへ埋め込まない。
    { name = "TOYBACO_APP_SECRET_VERSION", value = aws_secretsmanager_secret_version.app.version_id },
    { name = "TOYBACO_POSTIZ_SECRET_VERSION", value = aws_secretsmanager_secret_version.postiz.version_id },
  ]

  app_secrets = [
    { name = "SECRET_KEY_BASE", valueFrom = "${aws_secretsmanager_secret.app.arn}:SECRET_KEY_BASE::" },
    { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:POSTGRES_PASSWORD::" },
    { name = "SMTP_USERNAME", valueFrom = "${aws_secretsmanager_secret.app.arn}:SMTP_USERNAME::" },
    { name = "SMTP_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:SMTP_PASSWORD::" },
    # ご契約内容画面(カスタマーポータルのセッション発行)用の Stripe 制限付きキー
    { name = "TOYBACO_STRIPE_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:TOYBACO_STRIPE_KEY::" },

    # トイバコID の合言葉と、投稿画面側へ会社・利用者を作るための接続情報
    { name = "TOYBACO_OIDC_CLIENT_SECRET", valueFrom = "${aws_secretsmanager_secret.postiz.arn}:OIDC_CLIENT_SECRET::" },
    { name = "TOYBACO_POSTIZ_DATABASE_URL", valueFrom = "${aws_secretsmanager_secret.postiz.arn}:SYNC_DATABASE_URL::" },
  ]

  log_config = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.app.name
      awslogs-region        = "ap-northeast-1"
      awslogs-stream-prefix = "app"
    }
  }
}

# --- タスク定義 ---

resource "aws_ecs_task_definition" "rails" {
  family                   = "${local.project}-rails"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  skip_destroy             = true
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name             = "rails"
    image            = local.chatwoot_image
    essential        = true
    entryPoint       = ["docker/entrypoints/rails.sh"]
    command          = ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
    portMappings     = [{ containerPort = 3000, protocol = "tcp" }]
    environment      = local.app_environment
    secrets          = local.app_secrets
    logConfiguration = local.log_config
  }])

  tags = local.tags
}

resource "aws_ecs_task_definition" "sidekiq" {
  family                   = "${local.project}-sidekiq"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 1024
  skip_destroy             = true
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name             = "sidekiq"
    image            = local.chatwoot_image
    essential        = true
    command          = ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
    environment      = local.app_environment
    secrets          = local.app_secrets
    logConfiguration = local.log_config
  }])

  tags = local.tags
}

# Chatwoot migration直前のread-only schema_migrations基線検査。
# task roleを持たず、DB password以外のapplication secretも渡さない。
resource "aws_ecs_task_definition" "chatwoot_schema_preflight" {
  family                   = "${local.project}-chatwoot-schema-preflight"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([{
    name      = "chatwoot-schema-preflight"
    image     = local.chatwoot_image
    essential = true
    command   = ["/app/bin/toybaco-chatwoot-schema-preflight"]
    environment = [
      { name = "PGHOST", value = aws_db_instance.main.address },
      { name = "PGPORT", value = "5432" },
      { name = "PGDATABASE", value = "chatwoot" },
      { name = "PGUSER", value = "chatwoot" },
      { name = "PGSSLMODE", value = "require" },
      { name = "PGOPTIONS", value = "-c default_transaction_read_only=on" },
      { name = "TOYBACO_CHATWOOT_SCHEMA_BOOTSTRAP", value = "false" },
      { name = "TOYBACO_CHATWOOT_SCHEMA_REQUIRE_TARGET", value = "false" },
      { name = "TOYBACO_APP_SECRET_VERSION", value = aws_secretsmanager_secret_version.app.version_id },
    ]
    secrets = [
      { name = "PGPASSWORD", valueFrom = "${aws_secretsmanager_secret.app.arn}:POSTGRES_PASSWORD::" },
    ]
    logConfiguration = local.log_config
  }])

  tags = local.tags
}

# DBマイグレーション用（デプロイ時に aws ecs run-task で単発実行）
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${local.project}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  skip_destroy             = true
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "migrate"
    image     = local.chatwoot_image
    essential = true
    command   = ["bundle", "exec", "rails", "db:toybaco_prepare"]
    environment = concat(local.app_environment, [
      { name = "TOYBACO_CHATWOOT_BOOTSTRAP", value = "false" },
    ])
    secrets          = local.app_secrets
    logConfiguration = local.log_config
  }])

  tags = local.tags
}

# --- サービス ---

resource "aws_ecs_service" "rails" {
  name                               = "rails"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.rails.arn
  desired_count                      = var.initial_service_desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.rails.arn
    container_name   = "rails"
    container_port   = 3000
  }

  health_check_grace_period_seconds = 120

  depends_on = [aws_lb_listener.https]

  # Terraform はtask definitionを登録し、標準deploy workflowがmigration後に昇格する。
  # staging初回はdesired_count=0で作成し、同workflowが検証後に1へ上げる。
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = local.tags
}

resource "aws_ecs_service" "sidekiq" {
  name                               = "sidekiq"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.sidekiq.arn
  desired_count                      = var.initial_service_desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = local.tags
}
