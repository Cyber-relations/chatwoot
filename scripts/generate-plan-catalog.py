#!/usr/bin/env python3
"""Generate published plan terms from config/toybaco-plans.json; --check never writes.

Only explicitly marked HTML regions are generated. Product demos and page layout
outside these regions remain hand-authored. Adding a current sellable plan needs
no plan-name branch here, in the price calculator, or in signup navigation.
"""
import argparse
from decimal import Decimal, ROUND_HALF_UP
import html
import json
from pathlib import Path
import re
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
PAGES = ('site/index.html', 'site/pricing/index.html', 'site/signup/index.html')
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


def ai_count(plan):
    limit = plan['entitlements']['limits']['ai_replies']
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
    if not {'cards', 'runtime'}.issubset(found):
        raise ValueError(path + ': missing required generated regions')
    # Structured data is parsed so changes cannot corrupt unrelated schema fields.
    def schema(match):
        graph = json.loads(match.group(1))
        def visit(node):
            if isinstance(node, dict):
                if node.get('@type') == 'SoftwareApplication':
                    node['offers'] = [{'@type': 'Offer', 'name': p['name'], 'price': str(p['cycles']['month']['amount']), 'priceCurrency': 'JPY'} for p in sales(data)]
                for value in node.values():
                    visit(value)
            elif isinstance(node, list):
                for value in node:
                    visit(value)
        visit(graph)
        return '<script type="application/ld+json">' + json.dumps(graph, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c') + '</script>'
    return re.sub(r'<script type="application/ld\+json">(.*?)</script>', schema, result, flags=re.S)


def knowledge(data):
    lines = ['現在販売中のプランです。料金は税別です。契約中のお客様の金額・権利は契約時の条件で確認してください。']
    for plan in sales(data):
        ent = plan['entitlements']
        agents = ent['limits']['agents']
        price = '月額' + yen(plan['cycles']['month']['amount'])
        if 'year' in plan['cycles']:
            price += '、年一括' + yen(plan['cycles']['year']['amount'])
        terms = ('利用人数無制限' if agents is None else f'利用{agents:,}名まで')
        terms += '、SNS投稿' + ('あり' if ent['features']['posting'] else 'なし')
        terms += '、AI応答' + (ai_count(plan) if ent['features']['ai_reply'] else 'なし')
        url = 'https://toybaco.jp/' + link(plan, 'month', signup=True, root_page=True)
        lines.append(plan['name'] + ': ' + price + '。' + terms + '。申込: ' + url)
    return '\n'.join(lines)


def render_knowledge(source, data):
    pattern = r'(?m)^# toybaco-plans:knowledge:start\n.*?^# toybaco-plans:knowledge:end'
    replacement = '# toybaco-plans:knowledge:start\nPLAN_KNOWLEDGE = ' + repr(knowledge(data)) + '\n# toybaco-plans:knowledge:end'
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
        for page in PAGES:
            outputs[root / page] = render_page((root / page).read_text(), data, page).encode()
        bot = root / 'bot/handler.py'
        outputs[bot] = render_knowledge(bot.read_text(), data).encode()
    stale = [str(path.relative_to(root)) for path, expected in outputs.items() if not path.is_file() or path.read_bytes() != expected]
    if check and stale:
        raise ValueError('plan catalog outputs are stale: ' + ', '.join(stale) + '; run scripts/generate-plan-catalog.py')
    if not check:
        for path, expected in outputs.items():
            if not path.is_file() or path.read_bytes() != expected:
                path.write_bytes(expected)
    return stale


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--scope', choices=('all', 'overlay'), default='all',
                        help='Chatwoot publisher checks only its bundled catalog; private quality checks all consumers')
    args = parser.parse_args()
    try:
        generate(check=args.check, scope=args.scope)
    except (ValueError, KeyError) as error:
        raise SystemExit(str(error))
    print('PLAN_CATALOG=PASS')


if __name__ == '__main__':
    main()
