# frozen_string_literal: true

require_relative 'toybaco_durable_acceptance_test'
class ToybacoDurableAcceptanceTest
  def test_paid_upgrade_old_manifest_rejected_even_after_business_delete
    install
    insert('toybaco_growth_posting_paid_upgrades')
    assert markers.fetch('posting-paid-upgrade-v1')
    @db.exec('DELETE FROM toybaco_growth_posting_paid_upgrades; TRUNCATE toybaco_growth_posting_paid_upgrades')
    assert markers.fetch('posting-paid-upgrade-v1')
    old=Marshal.load(Marshal.dump(@manifest)); old['capabilities'].delete('posting-paid-upgrade-v1')
    assert_raises(ToybacoDurableStateProbe::Denied) { ToybacoDurableStateProbe.new(@db, old).read('c'*32) }
  end

  def test_paid_upgrade_rollback_never_sets_acceptance
    install
    @db.exec('BEGIN'); insert('toybaco_growth_posting_paid_upgrades'); @db.exec('ROLLBACK')
    refute markers.fetch('posting-paid-upgrade-v1')
  end

  def test_paid_upgrade_acceptance_remains_after_account_cascade_and_rejects_marker_truncate
    install; insert('accounts', 4); insert('toybaco_growth_posting_paid_upgrades', 1, account_id: 4)
    @db.exec('DELETE FROM accounts WHERE id=4')
    assert_equal '0', @db.exec('SELECT count(*) FROM toybaco_growth_posting_paid_upgrades').first.values.first
    assert markers.fetch('posting-paid-upgrade-v1')
    assert_raises(PG::CheckViolation) { @db.exec("TRUNCATE #{Definition::TABLE}") }
  end
end
