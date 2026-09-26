#!/usr/bin/env python3
"""Generate published plan terms from config/toybaco-plans.json; --check never writes.

Only explicitly marked HTML regions are generated. Product demos and page layout
outside these regions remain hand-authored. Adding a current sellable plan needs
no plan-name branch here, in the price calculator, or in signup navigation.
"""
import argparse
from decimal import Decimal, ROUND_HALF_UP
import html
import importlib.util
import json
from pathlib import Path
import re
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
PAGES = ('site/index.html', 'site/pricing/index.html', 'site/signup/index.html')
POLICY_PAGES = ('site/faq/index.html', 'site/terms/index.html', 'site/tokushoho/index.html')
DETAIL_PAGES = ('site/ai/index.html',)
MARKER = re.compile(r'<!-- toybaco-plans:([a-z_-]+):start -->(.*?)<!-- toybaco-plans:\1:end -->', re.S)


def sales(data):
    if data.get('schema_version') != 1 or data.get('currency') != 'jpy':
        raise ValueError('unsupported plan catalog schema or currency')
    result = []
    for plan_id, version in data['current_versions'].items():
        if not re.fullmatch(r'[a-z][a-z0-9_-]{0,63}', plan_id):
            raise ValueError('invalid plan identifier')
        terms = data['plans'][plan_id]['versions'][version]
        if not terms.get('sellable'):
            continue
        for cycle, price in terms['cycles'].items():
            if cycle not in ('month', 'year') or price['interval'] != cycle:
                raise ValueError('unsupported billing cycle')
            if type(price['amount']) is not int or price['amount'] < 0:
                raise ValueError('price must be a non-negative integer JPY amount')
        if 'month' not in terms['cycles']:
            raise ValueError('published plans need a monthly comparison price')
        result.append(dict(terms, plan_id=plan_id, version=version))
    if not result:
        raise ValueError('catalog has no sellable plans')
    return result


def yen(amount):
    value = Decimal(str(amount))
    # Annual monthly equivalents can be fractional; never hide the actual total.
    return '¥' + format(value, ',f').rstrip('0').rstrip('.') if value % 1 else '¥' + format(int(value), ',')


def taxed(amount, data):
    return int((Decimal(amount) * (1 + Decimal(str(data['display_tax_rate'])))).quantize(Decimal('1'), rounding=ROUND_HALF_UP))


def monthly_equivalent(amount):
    value = Decimal(amount) / 12
    return ('約' if value % 1 else '') + yen(value.quantize(Decimal('.01'), rounding=ROUND_HALF_UP))


def escape(value):
    return html.escape(str(value), quote=True)


def link(plan, cycle, signup=False, root_page=False):
    base = ('signup/' if root_page else '../signup/') if signup else 'https://app.toybaco.jp/toybaco/checkout'
    return base + '?' + urlencode({'plan': plan['plan_id'], 'cycle': cycle, 'version': plan['version']})


def growth_terms(plan):
    # Growth versions meter shared business generations (GrowthTerms::LIMITS), not replies.
    return 'ai_generations' in plan['entitlements']['limits']


def ai_count(plan):
    limits = plan['entitlements']['limits']
    if growth_terms(plan):
        return f"月{limits['ai_generations']:,}回"
    limit = limits['ai_replies']
    return '件数無制限' if limit is None else f'月{limit:,}件'


def features(plan):
    ent = plan['entitlements']
    flags, limits = ent['features'], ent['limits']
    channels = 'LINE・メール・Web チャット' + ('・Instagram DM' if flags['channel_instagram'] else '')
    items = [('', '問い合わせ一元管理(' + channels + ')')]
    agents = limits['agents']
    items.append(('', '利用人数 無制限' if agents is None else f'利用は{agents:,}名まで'))
    items.append(('', 'SNS 予約投稿・承認フロー') if flags['posting'] else ('no', 'SNS 投稿機能はありません'))
    items.append(('ai', 'AI 応答エージェント(' + ai_count(plan) + ')') if flags['ai_reply'] else ('no', 'AI 応答は含まれません'))
    stores = limits['stores']
    items.append(('', '店舗数 無制限' if stores is None else f'{stores:,}店舗分'))
    return '\n'.join('          <li' + (f' class="{cls}"' if cls else '') + '>' + escape(value) + '</li>' for cls, value in items)


def cards(plans, data, path):
    signup = path.endswith('signup/index.html')
    root_page = path == 'site/index.html'
    grid_id = ' id="sgPlans"' if signup else ''
    result = [f'<div class="plans2"{grid_id}>']
    for index, plan in enumerate(plans):
        featured = plan['entitlements']['features']['ai_reply']
        month = plan['cycles']['month']['amount']
        annual = plan['cycles'].get('year')
        year_display = monthly_equivalent(annual['amount']) if annual else '年払い対象外'
        mlink = link(plan, 'month', signup=not signup, root_page=root_page)
        ylink = link(plan, 'year', signup=not signup, root_page=root_page) if annual else ''
        result.extend([
            f'      <div class="plan2{" hot" if featured else ""} reveal" style="--d:{index * .06:.2f}s" data-plan="{escape(plan["plan_id"])}" data-version="{escape(plan["version"])}" id="plan-{escape(plan["plan_id"])}">',
            '        <span class="rec">AI 応答つき</span>' if featured else '',
            f'        <h3>{escape(plan["name"])}</h3>',
            f'        <p class="pfor">{escape(plan["description"])}</p>',
            f'        <p class="pprice"><b data-m="{yen(month)}" data-y="{year_display}">{yen(month)}</b><span> /月(税別)</span>' + (f'<i class="ybill">年一括 {yen(annual["amount"])}</i>' if annual and not signup else '') + '</p>',
        ])
        if signup:
            m_tax = '毎月 ' + yen(taxed(month, data)) + '(税込)'
            y_tax = '年一括 ' + yen(taxed(annual['amount'], data)) + '(税込)' if annual else '月払いでお申し込みください'
            result.append(f'        <p class="tax"><span data-m="{m_tax}" data-y="{y_tax}">{m_tax}</span></p>')
        result.extend([
            '        <ul>\n' + features(plan) + '\n        </ul>',
            f'        <a class="btn btn-{"coral" if featured else "ghost"} buy-btn" data-plan="{escape(plan["plan_id"])}" data-lm="{escape(mlink)}" data-ly="{escape(ylink)}" href="{escape(mlink)}">' + ('カードで申し込む' if signup else 'このプランではじめる') + '</a>',
            '      </div>',
        ])
    result.append('    </div>')
    return '\n'.join(line for line in result if line)


RUNTIME = r'''document.addEventListener('DOMContentLoaded', () => {
  const plans = JSON.parse(document.getElementById('toybaco-sales-data').textContent);
  const yen = n => '¥' + n.toLocaleString('ja-JP');
  const range = document.getElementById('calcRange');
  if (range) {
    const update = () => {
      const n = Number(range.value), seat = n * 8300;
      const eligible = plans.filter(p => p.agents === null || p.agents >= n).sort((a, b) => a.amount - b.amount);
      const plan = eligible[0];
      range.style.setProperty('--fill', (((n - 2) / 28) * 100).toFixed(1) + '%');
      document.getElementById('calcN').textContent = n;
      document.getElementById('valSeat').textContent = '月 約' + yen(seat);
      document.getElementById('lblToy').textContent = plan ? plan.product_name : 'この人数に対応する販売プランはありません';
      document.getElementById('valToy').textContent = plan ? '月 ' + yen(plan.amount) : 'ご相談ください';
      document.getElementById('barSeat').style.setProperty('--w', (seat / 249000 * 100).toFixed(1) + '%');
      document.getElementById('barToy').style.setProperty('--w', plan ? Math.min(100, plan.amount / 249000 * 100).toFixed(1) + '%' : '0%');
      document.getElementById('calcDiff').textContent = plan ? yen((seat - plan.amount) * 12) : '—';
    };
    range.addEventListener('input', update);
    update();
  }
  const buttons = document.querySelectorAll('.bill-tgl button');
  const priced = document.querySelectorAll('.plans2 [data-m]');
  const buys = document.querySelectorAll('.plans2 .buy-btn');
  const setCycle = yearly => {
    buttons.forEach(b => { const selected = b.dataset.bill === (yearly ? 'y' : 'm'); b.classList.toggle('on', selected); b.setAttribute('aria-pressed', String(selected)); });
    document.body.classList.toggle('bill-y', yearly);
    priced.forEach(el => { el.textContent = yearly ? el.dataset.y : el.dataset.m; });
    buys.forEach(a => {
      const href = yearly ? a.dataset.ly : a.dataset.lm;
      if (href) { a.href = href; a.removeAttribute('aria-disabled'); }
      else { a.removeAttribute('href'); a.setAttribute('aria-disabled', 'true'); }
    });
  };
  buttons.forEach(b => b.addEventListener('click', () => setCycle(b.dataset.bill === 'y')));
  const params = new URLSearchParams(location.search);
  setCycle(params.get('cycle') === 'year' || params.get('bill') === 'y');
  const selected = params.get('plan') || location.hash.replace(/^#/, '');
  const card = Array.from(document.querySelectorAll('#sgPlans .plan2')).find(el => el.dataset.plan === selected);
  if (card) {
    card.classList.add('picked');
    if (params.get('version') && params.get('version') !== card.dataset.version) {
      const notice = document.getElementById('plan-version-notice');
      notice.hidden = false;
      notice.textContent = '料金・プラン内容が更新されています。現在表示している条件をご確認のうえ、お申し込みください。';
    }
    card.scrollIntoView({ behavior: 'smooth', block: 'center' });
    const buy = card.querySelector('.buy-btn');
    if (buy) buy.focus({ preventScroll: true });
  }
});'''


def runtime(plans):
    public = [dict(plan_id=p['plan_id'], version=p['version'], name=p['name'], product_name=p['product_name'], amount=p['cycles']['month']['amount'], agents=p['entitlements']['limits']['agents']) for p in plans]
    # JSON lives in a raw-text element; escape '<' so catalog copy cannot end it.
    payload = json.dumps(public, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c')
    return '<script id="toybaco-sales-data" type="application/json">' + payload + '</script>\n<script>\n' + RUNTIME + '\n</script>'


def change_policy_text(data):
    changes = data['plan_changes']
    if not isinstance(changes.get('version'), str) or not changes['version']:
        raise ValueError('missing plan change policy version')
    labels = {
        'upgrade': '同じ支払周期の上位プランへの変更',
        'downgrade': '下位プランへの変更',
        'cycle_change': '月払い・年払いの切替',
    }
    actions = {
        ('after_payment', 'invoice_difference'): 'は、差額を日割りで請求し、決済成功後すぐに反映します。',
        ('period_end', 'none'): 'は、現在の契約期間の終了時に反映し、期間途中の追加請求・返金は行いません。',
    }
    grouped = {}
    for kind, label in labels.items():
        policy = changes['policies'][kind]
        key = (policy['effective'], policy['proration'])
        if key not in actions:
            raise ValueError('unsupported plan change policy')
        grouped.setdefault(key, []).append(label)
    return ''.join('と'.join(names) + actions[key] for key, names in grouped.items())


def billing_copy(data):
    plans = sales(data)
    if any(p.get('billing_policy', {}).get('cancellation') != 'period_end' for p in plans):
        raise ValueError('unsupported cancellation policy')
    cycles = {cycle for plan in plans for cycle in plan['cycles']}
    periods = '、'.join(label for cycle, label in [('month', '月払いは1か月'), ('year', '年払いは1年')] if cycle in cycles)
    return {
        'change_policy': escape(change_policy_text(data)),
        'change_scope': '変更可能なプラン・料金・適用日は「ご契約内容」でご確認ください。旧契約や追加オプションを含む契約の変更は、お問い合わせください。',
        'billing_periods': '契約期間はお申し込み時に選択する支払周期(' + periods + ')です。期間満了までに解約のお申し込みがない場合、契約時の条件で自動更新します。' + ('年払いは1年分の一括前払いです。' if 'year' in cycles else ''),
        'billing_payment': 'クレジットカード: お申し込み時に初回料金(該当する場合は初期設定費用を含む)を決済し、以後は選択した支払周期の更新日に自動決済します。月払いは毎月、年払いは毎年1年分を一括でお支払いいただきます。',
        'cancellation': '解約はいつでもお申し込みいただけます。次回の更新を停止し、現在の契約期間の終了までご利用いただけます。期間途中の解約による日割り返金はありません。',
        'legal_prices': '<ul>\n' + '\n'.join('    <li>' + escape(p['name']) + ': 月額 ' + yen(p['cycles']['month']['amount']) +
                                          (' / 年一括 ' + yen(p['cycles']['year']['amount']) if 'year' in p['cycles'] else '') + '</li>' for p in plans) + '\n  </ul>',
    }


def ai_copy(plan):
    available = plan is not None
    name = plan['name'] if available else 'AI 対応プラン'
    count = ai_count(plan) if available else '販売プランの掲載準備中'
    inclusion = name + 'プランに' + count + 'のAI応答を標準搭載しています。' if available else 'AI 応答対応プランは、料金ページでご確認ください。'
    description = 'お店のFAQをもとにAIが営業時間外や混雑時の問い合わせに一次応答。答えられない相談は人に引き継ぎ。' + inclusion
    summary = '現在のAI応答対応プランは、料金ページでご確認ください。'
    if available:
        entitlements = plan['entitlements']
        agents = entitlements['limits']['agents']
        summary = 'AI 応答エージェント <b>' + escape(count) + '</b>を標準搭載。'
        if entitlements['features']['posting']:
            summary += 'SNS予約投稿・承認フローも使えます。'
        summary += '利用人数は無制限です。' if agents is None else f'利用は{agents:,}名までです。'
    return {
        'ai_description': '<meta name="description" content="' + escape(description) + '">',
        'ai_og_description': '<meta property="og:description" content="' + escape(description) + '">',
        'ai_inclusion': escape(inclusion),
        'ai_caption': escape(name + 'プランに標準搭載') if available else '料金ページでご確認ください',
        'ai_plan_name': escape(name),
        'ai_price_heading': 'AI 応答つきで、月 ' + yen(plan['cycles']['month']['amount']) if available else 'AI 応答の料金は、料金ページでご確認ください',
        'ai_month_price': yen(plan['cycles']['month']['amount']) + '<small> /月(税別)</small>' if available else '掲載準備中',
        'ai_plan_summary': summary,
    }


def replacements(data, path):
    plans = sales(data)
    cheapest = min(plans, key=lambda p: p['cycles']['month']['amount'])
    minimum = yen(cheapest['cycles']['month']['amount'])
    ai = [p for p in plans if p['entitlements']['features']['ai_reply']]
    ai_plan = min(ai, key=lambda p: p['cycles']['month']['amount']) if ai else None
    showcase = ai_plan or cheapest
    caps = '、'.join(escape(p['name']) + f'は{p["entitlements"]["limits"]["agents"]:,}名まで' for p in plans if p['entitlements']['limits']['agents'] is not None)
    discounted = [Decimal(1) - Decimal(p['cycles']['year']['amount']) / (p['cycles']['month']['amount'] * 12) for p in plans if 'year' in p['cycles'] and p['cycles']['month']['amount']]
    same_discount = len(discounted) == len(plans) and len(set(discounted)) == 1 and discounted[0] > 0 and (discounted[0] * 100) % 1 == 0
    discount = format(discounted[0] * 100, '.0f') + '%オフ' if same_discount else '年一括払い'
    price_description = 'トイバコの料金は店舗ごとの定額制。' + '/'.join(p['name'] + yen(p['cycles']['month']['amount']) for p in plans) + '(月・税別)。利用人数・AI応答枠はプランごとの契約条件をご確認ください。'
    base_description = '問い合わせ・SNS予約投稿・AI応答をひとつに。トイバコは月' + minimum + 'から。機能と利用人数・AI応答枠はプランにより異なります。'
    title = ('料金プラン — 月' + minimum + 'から | トイバコ') if '/pricing/' in path else ('トイバコ | 問い合わせ・SNS投稿・AI応答をひとつに 月' + minimum + 'から')
    description = price_description if '/pricing/' in path else base_description
    result = {
        **billing_copy(data),
        **ai_copy(ai_plan),
        'cards': cards(plans, data, path),
        'runtime': runtime(plans),
        'title': '<title>' + escape(title) + '</title>',
        'og_title': '<meta property="og:title" content="' + escape(title) + '">',
        'description': '<meta name="description" content="' + escape(description) + '">',
        'og_description': '<meta property="og:description" content="' + escape(description) + '">',
        'minimum': minimum,
        'minimum_plain': minimum.replace('¥', ''),
        'discount': escape(discount),
        'plan_count': f'全{len(plans)}プラン。すべて店舗ごとの定額',
        'seat_note': '人数に応じた追加課金はありません。プランごとの人数上限があります' + ('(' + caps + ')' if caps else '') + '。',
        'price_notes': '価格はすべて税別です。月払いの税込目安: ' + ' / '.join(escape(p['name']) + ' ' + yen(taxed(p['cycles']['month']['amount'], data)) for p in plans) + '。<br>年払いは1年分の一括前払いです。解約後は契約期間の終了までご利用いただけます。追加店舗・接続代行の提供条件と料金は、決済画面または事前のお見積もりでご確認ください。',
        'ai_count': escape(ai_count(ai_plan)) if ai_plan else '販売プランの掲載準備中',
        'ai_name': escape(ai_plan['name'] + 'プラン') if ai_plan else 'AI 対応プラン',
        'showcase_name': escape(showcase['name'] + 'プラン'),
        'showcase_price': yen(showcase['cycles']['month']['amount']),
    }
    eligible = sorted((p for p in plans if p['entitlements']['limits']['agents'] is None or p['entitlements']['limits']['agents'] >= 10), key=lambda p: p['cycles']['month']['amount'])
    result['calc_name'] = escape(eligible[0]['product_name']) if eligible else 'ご相談ください'
    result['calc_price'] = '月 ' + yen(eligible[0]['cycles']['month']['amount']) if eligible else '対応プランはありません'
    result['calc_difference'] = yen((83000 - eligible[0]['cycles']['month']['amount']) * 12) if eligible else '—'
    return result


def render_page(source, data, path):
    values = replacements(data, path)
    found = set()
    def replace(match):
        key = match.group(1)
        if key not in values:
            raise ValueError('unknown generated region: ' + key)
        found.add(key)
        return f'<!-- toybaco-plans:{key}:start -->{values[key]}<!-- toybaco-plans:{key}:end -->'
    result = MARKER.sub(replace, source)
    required = {'cards', 'runtime', 'change_policy'} if path in PAGES else {'change_policy', 'cancellation', 'billing_periods'}
    if path in DETAIL_PAGES:
        required = set(ai_copy(None)) | {'ai_count'}
    if path == 'site/tokushoho/index.html':
        required |= {'billing_payment', 'legal_prices'}
    if not required.issubset(found):
        raise ValueError(path + ': missing required generated regions')
    # Structured data is parsed so changes cannot corrupt unrelated schema fields.
    def schema(match):
        graph = json.loads(match.group(1))
        def visit(node):
            if isinstance(node, dict):
                if node.get('@type') == 'SoftwareApplication':
                    node['offers'] = [{'@type': 'Offer', 'name': p['name'], 'price': str(p['cycles']['month']['amount']), 'priceCurrency': 'JPY'} for p in sales(data)]
                if node.get('@type') == 'Question':
                    copy = billing_copy(data)
                    answers = {
                        'プランの変更はできますか?': change_policy_text(data) + copy['change_scope'],
                        '契約期間の縛りや違約金はありますか?': copy['billing_periods'] + copy['cancellation'],
                        '解約の手続きはどうすればいいですか?': copy['cancellation'],
                    }
                    if node.get('name') in answers:
                        node['acceptedAnswer']['text'] = answers[node['name']]
                for value in node.values():
                    visit(value)
            elif isinstance(node, list):
                for value in node:
                    visit(value)
        visit(graph)
        return '<script type="application/ld+json">' + json.dumps(graph, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c') + '</script>'
    return re.sub(r'<script type="application/ld\+json">(.*?)</script>', schema, result, flags=re.S)


# Bot knowledge copy. The fixed sentences restate LP copy (lp_pricing_candidate.py); prices, limits and links come from the catalog.
SALES_KNOWLEDGE_HEADER = '現在販売中のプランです。料金は税別です。契約中のお客様の金額・権利は契約時の条件で確認してください。'
LP_KNOWLEDGE_HEADER = '現在ご案内中のプランです。料金は1店舗ごとの税別価格で、全プランでスタッフ数は無制限です。契約中のお客様の金額・権利は契約時の条件で確認してください。'
APPLY_BY_FORM = '申し込みページでプランと支払周期を選ぶと、内容が相談フォームに引き継がれます。有料プランはお問い合わせフォームでお申し込みを承り、内容の確認後に担当者からご連絡します(販売開始後はカード決済に対応)。'
APPLY_FREE_BY_EMAIL = '無料プランはメール確認で開始できます(カード登録不要)。'
# The start of paid service is stated as the LP 特定商取引法・利用規約 state it; no fixed opening lead time is promised.
APPLY_BY_CARD = '有料プランはクレジットカード(Stripe の決済画面によるWeb決済)でお申し込みいただき、初回決済の成功を確認して開始します。最終金額は決済画面でご確認ください。接続作業・審査に必要な期間は媒体や店舗の状態によって異なります。'
BILLED_AMOUNT = '請求額は税額・割引・追加項目によって変わります。'
PLAN_CHANGE_QUESTION = 'プラン変更・解約はいつ反映されますか？'
TRIAL_QUESTION = 'AI自動返信の体験はいつ始まりますか？'


def annual_discount(month, annual):
    # Only an exact whole-percent discount is stated; the annual total itself is always shown.
    if not month:
        return ''
    percent = (1 - Decimal(annual) / (Decimal(month) * 12)) * 100
    return f'({percent:.0f}%割引)' if percent > 0 and percent % 1 == 0 else ''


def application_links(url, year_url):
    """A plan's application links: one reads "申込", a plan with both billing cycles labels each of them.

    Each cycle offered is linked, so an annual applicant is not sent to the monthly checkout. The bot finds the links
    by these labels. Every URL is followed by a space or a line break only, the one boundary the bot accepts after a
    link (a chat renderer would carry other characters into the href), so a reply copying this form stays valid.
    """
    return '申込: ' + url if year_url is None else '申込(月払い): ' + url + ' 申込(年払い): ' + year_url


def plan_line(name, month, annual, limits, automatic, pack, url, year_url, *, free):
    """One plan in the bot's words. LP candidate plans and promoted growth terms share this sentence."""
    if free:
        price = yen(month) + '(カード登録不要)'
    else:
        price = '月額' + yen(month) + ('' if annual is None else '、年一括' + yen(annual) + annual_discount(month, annual))
    links = application_links(url, year_url)
    counts = [limits[key] for key in ('inboxes', 'posting_accounts', 'scheduled_posts_per_account', 'ai_generations')]
    if any(type(count) is not int or count < 0 for count in counts):
        raise ValueError('plan limits must be non-negative integers')
    # Numbers are written as on the LP cards: connections without and reservations or generations with separators.
    # Like the cards ("通常の自動返信は対象外"), plans without automatic replies may still offer the trial.
    terms = [f"受信箱{limits['inboxes']}接続", f"投稿先{limits['posting_accounts']}接続",
             f"同時予約は投稿先ごとに{limits['scheduled_posts_per_account']:,}件", f"AI生成 月{limits['ai_generations']:,}回",
             'AI自動返信あり' if automatic else '通常のAI自動返信は対象外'] + (['AI追加パック購入可'] if pack else [])
    return name + ': ' + price + '。' + '、'.join(terms) + '。' + links


def application_line(connected, free_offered):
    # The LP takes applications through the consultation form until the application routes are connected.
    route = ((APPLY_FREE_BY_EMAIL if free_offered else '') + APPLY_BY_CARD) if connected else APPLY_BY_FORM
    return '申し込み方法: ' + route + BILLED_AMOUNT


LP_SITE = 'https://toybaco.jp'
LP_CARD_LINK = re.compile(r'data-lp-plan-link="([^"]*)" href="([^"]*)"')
LINKS_CHANGED = 'LP plan card links changed; review the bot knowledge links'


def lp_card_links(candidate, plans, data, connected):
    """The LP plan card destinations, read from the candidate's own cards() so the bot keeps no second URL rule.

    The pricing cards link the signup page. Once the application routes are connected, the signup cards link the app.
    cards() reads that from APP_ROUTES_CONNECTED, so an explicit choice is applied to it only while rendering.
    """
    flag = candidate.APP_ROUTES_CONNECTED
    candidate.APP_ROUTES_CONNECTED = connected
    try:
        rendered = candidate.cards(plans, data, signup=connected)
    finally:
        candidate.APP_ROUTES_CONNECTED = flag
    links = [(plan_id, html.unescape(href)) for plan_id, href in LP_CARD_LINK.findall(rendered)]
    if [plan_id for plan_id, _ in links] != ['free', 'light', 'standard', 'pro']:
        raise ValueError(LINKS_CHANGED)
    urls = {}
    for plan_id, href in links:
        if href.startswith('/') and not href.startswith('//'):
            href = LP_SITE + href
        elif not href.startswith('https://'):
            raise ValueError(LINKS_CHANGED)
        urls[plan_id] = href
    return urls


def annual_link(url):
    # The LP script switches a paid card to annual billing by setting cycle=year in place (candidate.js setCycle).
    if url.count('cycle=month') != 1:
        raise ValueError(LINKS_CHANGED)
    return url.replace('cycle=month', 'cycle=year')


def lp_knowledge(data, candidate, connected):
    if connected is not True and connected is not False:
        raise ValueError('the application route choice must be True or False')
    plans, terms = candidate.load_plans(data, candidate.VERSION)
    pack = terms['ai_pack']
    buyers = [p['plan_id'] for p in plans if p['pack']]
    trial = terms.get('auto_reply_trial') or {}
    trial_plans = [p['name'] for p in plans if not p['automatic']]
    # The fixed sentences here and on the LP state these terms: the LP cards and FAQ say annual billing is 10% off,
    # and its pack panel and FAQ name Standard・Pro, in that order, as the buyers. The pack figures are whole yen and
    # days as on the LP. The trial is once per store, started by the owner, and never charged automatically. A catalog
    # that contradicts them needs reviewed copy. The plan prices carry no tax field of their own to check.
    if (any(p['limits']['agents'] is not None or p['limits'].get('stores') != 1 for p in plans)
            or any(Decimal(p['annual']) != Decimal(p['amount']) * 12 * Decimal('0.9') for p in plans if not p['free'])
            or pack.get('automatic_purchase') is not False or pack.get('tax_behavior') != 'exclusive'
            or any(type(pack.get(key)) is not int or pack[key] <= 0 for key in ('generations', 'amount', 'expires_after_days'))
            or set(buyers) != set(pack['purchase_plans']) or buyers != ['standard', 'pro']
            or (trial_plans and (trial.get('once_per_store') is not True or trial.get('requires_owner_start') is not True
                                 or trial.get('automatic_charge') is not False
                                 or any(type(trial.get(key)) is not int or trial[key] <= 0 for key in ('days', 'generations'))))):
        raise ValueError('LP candidate terms contradict the bot knowledge copy; review it before generating')
    # Plan changes and cancellation quote the one LP FAQ answer, which the candidate builds from CHANGE and LEGACY.
    answers = [answer for question, answer in candidate.faq_items(plans, terms) if question == PLAN_CHANGE_QUESTION]
    if len(answers) != 1 or not isinstance(answers[0], str) or not answers[0].strip():
        raise ValueError('LP FAQ no longer answers plan changes and cancellation; review the bot knowledge copy')
    change = answers[0]
    urls = lp_card_links(candidate, plans, data, connected)
    lines = [LP_KNOWLEDGE_HEADER]
    for p in plans:
        url = urls[p['plan_id']]
        lines.append(plan_line(p['name'], p['amount'], p['annual'], p['limits'], p['automatic'], p['pack'],
                               url, None if p['free'] else annual_link(url), free=p['free']))
    labels = '・'.join(plan_id.capitalize() for plan_id in buyers)  # The LP names them in English: "Standard・Pro".
    lines.append(f"AI追加パック: {pack['generations']:,}回 {yen(pack['amount'])}(税別)。{labels}で購入でき、"
                 f"決済成功から{pack['expires_after_days']}日間有効です。自動購入はありません。")
    if trial_plans:
        # The LP FAQ offers plans without automatic replies a trial of them (candidate auto_reply_trial). Where the trial
        # runs is quoted from the candidate (TRIAL_INBOXES), which the LP FAQ answer must state once.
        answers = [answer for question, answer in candidate.faq_items(plans, terms) if question == TRIAL_QUESTION]
        if len(answers) != 1 or not isinstance(answers[0], str) or answers[0].count(candidate.TRIAL_INBOXES) != 1:
            raise ValueError('LP FAQ no longer states where the trial runs; review the bot knowledge copy')
        lines.append(f"AI自動返信の体験: {'・'.join(trial_plans)}では、準備完了後にオーナーが開始してから{trial['days']}日または"
                     f"{trial['generations']:,}回に達するまで、1店舗につき1回体験できます。自動課金はありません。"
                     + candidate.TRIAL_INBOXES)
    lines.append(application_line(connected, free_offered=any(p['free'] for p in plans)))
    lines.append('プラン変更・解約: ' + change)
    return '\n'.join(lines)


def knowledge(data, candidate=None, connected=None):
    """Bot knowledge for the plans the public LP shows.

    With the LP candidate module (the LP renders its version), the candidate plans are stated and the application
    route follows `connected`, by default the module's APP_ROUTES_CONNECTED. Without it, the current sellable versions
    are stated with the card checkout route of the version-pinned signup pages.
    """
    if candidate is not None:
        return lp_knowledge(data, candidate, candidate.APP_ROUTES_CONNECTED if connected is None else connected)
    if connected is not None:
        raise ValueError('the application route choice applies only to the LP candidate')
    lines = [SALES_KNOWLEDGE_HEADER]
    for plan in sales(data):
        ent = plan['entitlements']
        # Every line here is a paid plan; a zero monthly price would read as "月額¥0" for a plan sold by card.
        if plan['cycles']['month']['amount'] == 0:
            raise ValueError('current sales plans need a positive monthly price in the bot knowledge')
        # Without the candidate the LP cards link its signup page for both cycles (data-lm / data-ly) in every version.
        url = 'https://toybaco.jp/' + link(plan, 'month', signup=True, root_page=True)
        annual = plan['cycles']['year']['amount'] if 'year' in plan['cycles'] else None
        year_url = None if annual is None else 'https://toybaco.jp/' + link(plan, 'year', signup=True, root_page=True)
        if growth_terms(plan):
            lines.append(plan_line(plan['name'], plan['cycles']['month']['amount'], annual, ent['limits'],
                                   ent['features']['ai_auto_reply'], ent['features']['ai_pack_purchase'], url, year_url, free=False))
            continue
        agents = ent['limits']['agents']
        price = '月額' + yen(plan['cycles']['month']['amount'])
        if annual is not None:
            price += '、年一括' + yen(annual)
        terms = ('利用人数無制限' if agents is None else f'利用{agents:,}名まで')
        terms += '、SNS投稿' + ('あり' if ent['features']['posting'] else 'なし')
        terms += '、AI応答' + (ai_count(plan) if ent['features']['ai_reply'] else 'なし')
        lines.append(plan['name'] + ': ' + price + '。' + terms + '。' + application_links(url, year_url))
    # sales() never lists a free plan: it requires a monthly price.
    lines.append(application_line(connected=True, free_offered=False))
    lines.append('プラン変更: ' + change_policy_text(data) + billing_copy(data)['change_scope'])
    return '\n'.join(lines)


def render_knowledge(source, data, candidate=None, connected=None):
    pattern = r'(?m)^# toybaco-plans:knowledge:start\n.*?^# toybaco-plans:knowledge:end'
    replacement = '# toybaco-plans:knowledge:start\nPLAN_KNOWLEDGE = ' + repr(knowledge(data, candidate, connected)) + '\n# toybaco-plans:knowledge:end'
    rendered, count = re.subn(pattern, lambda _: replacement, source, flags=re.S)
    if count != 1:
        raise ValueError('bot/handler.py: expected one generated knowledge region')
    return rendered


def generate(root=ROOT, check=False, scope='all'):
    if scope not in ('all', 'overlay'):
        raise ValueError('unsupported generation scope')
    source = root / 'config/toybaco-plans.json'
    raw = source.read_bytes()
    data = json.loads(raw)
    sales(data)
    outputs = {root / 'overlay/app/config/toybaco-plans.json': raw}
    if scope == 'all':
        pricing_candidate = re.search(r'<!-- toybaco-lp-(?:pricing|announcement):\d{4}-\d{2}-\d{2}\.\d+ -->', (root / 'site/index.html').read_text()) is not None
        candidate = candidate_module() if pricing_candidate else None
        if candidate is not None:
            for name, content in candidate.rendered_files(root, candidate.VERSION, preview=False).items():
                if name != 'lp-candidate-manifest.json':
                    outputs[root / 'site' / name] = content
        else:
            for page in PAGES + POLICY_PAGES + DETAIL_PAGES:
                outputs[root / page] = render_page((root / page).read_text(), data, page).encode()
        bot = root / 'bot/handler.py'
        # The official chat states what the LP shows: its candidate version while the LP renders one.
        outputs[bot] = render_knowledge(bot.read_text(), data, candidate=candidate).encode()
    stale = [str(path.relative_to(root)) for path, expected in outputs.items() if not path.is_file() or path.read_bytes() != expected]
    if check and stale:
        raise ValueError('plan catalog outputs are stale: ' + ', '.join(stale) + '; run scripts/generate-plan-catalog.py')
    if not check:
        for path, expected in outputs.items():
            if not path.is_file() or path.read_bytes() != expected:
                path.write_bytes(expected)
    return stale


def candidate_module():
    spec = importlib.util.spec_from_file_location('lp_candidate', Path(__file__).with_name('lp_pricing_candidate.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--scope', choices=('all', 'overlay'), default='all',
                        help='Chatwoot publisher checks only its bundled catalog; private quality checks all consumers')
    parser.add_argument('--candidate-version', help='explicit non-published LP candidate version')
    parser.add_argument('--output', type=Path, help='candidate only: directory under this checkout/output/')
    parser.add_argument('--public-candidate', action='store_true', help='candidate output with production URLs; publication still requires release gates')
    args = parser.parse_args()
    try:
        if args.candidate_version:
            if args.output is None or args.scope != 'all':
                raise ValueError('candidate requires --output and --scope all')
            candidate_module().generate_candidate(ROOT, args.candidate_version, args.output, check=args.check, preview=not args.public_candidate)
        else:
            if args.output is not None or args.public_candidate:
                raise ValueError('--output/--public-candidate require --candidate-version')
            generate(check=args.check, scope=args.scope)
    except (ValueError, KeyError) as error:
        raise SystemExit(str(error))
    print('PLAN_CATALOG=PASS')


if __name__ == '__main__':
    main()
