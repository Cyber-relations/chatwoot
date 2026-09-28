# frozen_string_literal: true

# 運営操作の監査ログ(S1-1)。SuperAdmin・rake・ops-rake workflow の操作を追記専用で残す。
# 引数の生値は保存せず、canonical JSON の SHA-256(params_digest)だけを持つ。更新時刻(updated_at)は持たない。
# actor_id・source・target_type は文字種まで CHECK で限り、氏名やメールアドレスのような値を入れない。
# 保持は 7 年の方針で削除ジョブは作らない。rollback でも監査の記録を消さないため down は止める。
class CreateToybacoOperatorActions < ActiveRecord::Migration[7.1]
  TABLE = :toybaco_operator_actions
  # 追記専用のトリガ関数。UPDATE と TRUNCATE は常に拒否し、DELETE は保持期間(7 年)を過ぎた行だけを許す(将来の purge 用)。
  # モデルの readonly? は AR 経由の更新・削除しか止められないため、row.delete・update_all・直接 SQL も DB で止める。
  # 作法は durable acceptance の immutable トリガ(lib/toybaco/durable_acceptance.rb)に揃える。
  APPEND_ONLY_FUNCTION = <<~SQL.squish
    CREATE FUNCTION public.toybaco_operator_actions_append_only() RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY INVOKER
    SET search_path = pg_catalog, public AS $function$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF OLD.created_at < now() - interval '7 years' THEN
          RETURN OLD;
        END IF;
      END IF;
      RAISE EXCEPTION 'toybaco operator actions are append-only' USING ERRCODE = '23514';
    END;
    $function$
  SQL

  def up
    # created_at は timestamptz(既定値は DB の now())。追記専用のため updated_at を持たない。
    create_table TABLE do |t| # rubocop:disable Rails/CreateTableWithTimestamps
      t.string :actor_kind, null: false
      t.string :actor_id, null: false
      t.string :action, null: false
      t.string :target_type
      t.bigint :target_id
      t.string :params_digest
      t.string :result, null: false
      t.string :source
      t.timestamptz :created_at, null: false, default: -> { 'now()' }
    end
    indexes
    constraints
    append_only
  end

  def down
    raise ActiveRecord::IrreversibleMigration, '運営操作の監査ログは rollback で消さない'
  end

  private

  def indexes
    add_index TABLE, :created_at, name: 'index_tb_operator_actions_created'
    add_index TABLE, %i[target_type target_id created_at], name: 'index_tb_operator_actions_target'
    add_index TABLE, %i[actor_kind actor_id created_at], name: 'index_tb_operator_actions_actor'
  end

  def constraints
    add_check_constraint TABLE, "actor_kind IN ('super_admin', 'rake', 'workflow', 'job')", name: 'tb_operator_actor_kind'
    add_check_constraint TABLE, "actor_id ~ '^[A-Za-z0-9:_.-]{1,128}$'", name: 'tb_operator_actor_id'
    add_check_constraint TABLE, "action ~ '^[a-z0-9_.:-]{1,128}$'", name: 'tb_operator_action'
    add_check_constraint TABLE, '(target_type IS NULL) = (target_id IS NULL)', name: 'tb_operator_target'
    add_check_constraint TABLE, "target_type IS NULL OR target_type ~ '^[A-Za-z0-9:]{1,128}$'", name: 'tb_operator_target_type'
    add_check_constraint TABLE, "params_digest IS NULL OR params_digest ~ '^[0-9a-f]{64}$'", name: 'tb_operator_params_digest'
    add_check_constraint TABLE, "result IN ('started', 'ok', 'rejected', 'failed')", name: 'tb_operator_result'
    add_check_constraint TABLE, "source IS NULL OR source ~ '^[A-Za-z0-9:_.-]{1,128}$'", name: 'tb_operator_source'
  end

  def append_only
    execute APPEND_ONLY_FUNCTION
    execute 'CREATE TRIGGER toybaco_operator_actions_immutable_row BEFORE UPDATE OR DELETE ON public.toybaco_operator_actions ' \
            'FOR EACH ROW EXECUTE FUNCTION public.toybaco_operator_actions_append_only()'
    execute 'CREATE TRIGGER toybaco_operator_actions_immutable_truncate BEFORE TRUNCATE ON public.toybaco_operator_actions ' \
            'FOR EACH STATEMENT EXECUTE FUNCTION public.toybaco_operator_actions_append_only()'
  end
end
