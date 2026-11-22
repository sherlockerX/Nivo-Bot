/* 网站只读取公开版本清单；不收集API Key，不调用模型服务。 */
(() => {
  'use strict';
  const root = new URL(document.body.dataset.root || './', document.baseURI);
  const status = document.querySelector('#page-status');

  /** 向辅助技术报告交互结果。 */
  function announce(message) { if (status) status.textContent = message; }

  /** 所有下载与外链都限制为HTTPS，内部说明页限制在本站。 */
  function safeUrl(value, internal = false) {
    if (typeof value !== 'string' || !value.trim()) throw new Error('缺少链接');
    const parsed = new URL(value, root);
    if (parsed.protocol !== 'https:' && !(internal && parsed.origin === location.origin)) throw new Error('不支持的链接');
    if (internal && parsed.origin !== root.origin) throw new Error('说明页必须属于本站');
    return parsed.href;
  }

  /** 创建纯文字节点，版本数据不作为HTML执行。 */
  function node(tag, text, className = '') {
    const result = document.createElement(tag);
    if (text !== undefined) result.textContent = text;
    if (className) result.className = className;
    return result;
  }

  /** 建立经过协议验证的链接。 */
  function anchor(text, url, className = '', internal = false) {
    const result = node('a', text, className);
    result.href = safeUrl(url, internal);
    return result;
  }

  /** 收起移动端导航，并同步无障碍状态。 */
  function navigation() {
    const button = document.querySelector('.menu-button');
    const nav = document.querySelector('#navigation');
    if (!button || !nav) return;
    const close = () => { button.setAttribute('aria-expanded', 'false'); nav.dataset.open = 'false'; };
    button.addEventListener('click', () => {
      const open = button.getAttribute('aria-expanded') !== 'true';
      button.setAttribute('aria-expanded', String(open)); nav.dataset.open = String(open);
    });
    nav.addEventListener('click', event => { if (event.target.closest('a')) close(); });
    document.addEventListener('keydown', event => {
      if (event.key !== 'Escape' || button.getAttribute('aria-expanded') !== 'true') return;
      close(); button.focus();
    });
    document.addEventListener('click', event => {
      if (!event.target.closest('.site-header')) close();
    });
    const desktop = matchMedia('(min-width: 761px)');
    desktop.addEventListener('change', close);
  }

  /** 首页示意由访客选择阶段，不自动切换，不写入任何应用数据。 */
  function dayStory(region) {
    const tabs = [...region.querySelectorAll('[data-story-tab]')];
    const panels = [...region.querySelectorAll('[role=tabpanel]')];
    const show = index => {
      tabs.forEach((tab, position) => {
        const selected = position === index;
        tab.setAttribute('aria-selected', String(selected));
        tab.tabIndex = selected ? 0 : -1;
        panels[position].hidden = !selected;
      });
    };
    tabs.forEach((tab, index) => {
      tab.addEventListener('click', () => show(index));
      tab.addEventListener('keydown', event => {
        const targets = {ArrowLeft: (index + tabs.length - 1) % tabs.length,
          ArrowRight: (index + 1) % tabs.length, Home: 0, End: tabs.length - 1};
        if (!(event.key in targets)) return;
        event.preventDefault(); show(targets[event.key]); tabs[targets[event.key]].focus();
      });
    });
  }

  /** 手机先展示教程内容，仍保留随时展开的服务商目录。 */
  function guideNavigation() {
    const directory = document.querySelector('.guide-nav details');
    if (!directory) return;
    const mobile = matchMedia('(max-width: 760px)');
    const update = () => { directory.open = !mobile.matches; };
    mobile.addEventListener('change', update); update();
  }

  /** 轮播提供键盘、触摸、暂停，以及视口和减少动态效果处理。 */
  function carousel(region) {
    const panels = [...region.querySelectorAll('.slide')];
    const tabs = [...region.querySelectorAll('[data-slide]')];
    const count = region.querySelector('[data-carousel-count]');
    const playButton = region.querySelector('[data-carousel-play]');
    const stage = region.querySelector('.gallery-stage');
    const reduced = matchMedia('(prefers-reduced-motion: reduce)');
    let current = 0, playing = false, inView = false, hovering = false, focused = false;
    let timer = null, touch = null;
    const pauseLabel = () => {
      playButton.textContent = playing ? '暂停' : '播放';
      playButton.setAttribute('aria-label', playing ? '暂停自动轮播' : '播放自动轮播');
    };
    const schedule = () => {
      clearTimeout(timer);
      if (playing && inView && !hovering && !focused && !document.hidden) timer = setTimeout(() => show(current + 1), 6500);
    };
    const show = index => {
      current = (index + panels.length) % panels.length;
      panels.forEach((panel, i) => { panel.hidden = i !== current; });
      tabs.forEach((tab, i) => { tab.setAttribute('aria-selected', String(i === current)); tab.tabIndex = i === current ? 0 : -1; });
      count.textContent = `${String(current + 1).padStart(2, '0')} / ${String(panels.length).padStart(2, '0')}`;
      schedule();
    };
    tabs.forEach((tab, i) => tab.addEventListener('click', () => show(i)));
    region.querySelector('[data-carousel-prev]').addEventListener('click', () => show(current - 1));
    region.querySelector('[data-carousel-next]').addEventListener('click', () => show(current + 1));
    playButton.addEventListener('click', () => { playing = !playing; pauseLabel(); schedule(); });
    region.addEventListener('keydown', event => {
      if (event.target !== region && !event.target.matches('[role=tab]')) return;
      const keys = { ArrowLeft: current - 1, ArrowRight: current + 1, Home: 0, End: panels.length - 1 };
      if (!(event.key in keys)) return;
      event.preventDefault(); show(keys[event.key]);
      if (event.target.matches('[role=tab]')) tabs[current].focus();
    });
    region.addEventListener('mouseenter', () => { hovering = true; schedule(); });
    region.addEventListener('mouseleave', () => { hovering = false; schedule(); });
    region.addEventListener('focusin', () => { focused = true; schedule(); });
    region.addEventListener('focusout', event => { focused = region.contains(event.relatedTarget); schedule(); });
    // 标签栏需要独立横向滚动，只有画面区域的手势可以切换当前功能。
    stage.addEventListener('touchstart', event => { touch = event.changedTouches[0]; }, { passive: true });
    stage.addEventListener('touchcancel', () => { touch = null; }, { passive: true });
    stage.addEventListener('touchend', event => {
      if (!touch) return;
      const end = event.changedTouches[0], dx = end.clientX - touch.clientX, dy = end.clientY - touch.clientY;
      if (Math.abs(dx) > 45 && Math.abs(dx) > Math.abs(dy) * 1.4) show(current + (dx < 0 ? 1 : -1));
      touch = null;
    }, { passive: true });
    new IntersectionObserver(entries => { inView = entries[0].isIntersecting; schedule(); }, { threshold: .12 }).observe(region);
    document.addEventListener('visibilitychange', schedule);
    reduced.addEventListener('change', () => { if (reduced.matches) playing = false; pauseLabel(); schedule(); });
    pauseLabel(); show(0);
  }

  /** 同时应用关键词和类别筛选，原生链接保留独立页面。 */
  function providerSearch() {
    const input = document.querySelector('#provider-search');
    if (!input) return;
    const cards = [...document.querySelectorAll('[data-provider]')];
    const filters = [...document.querySelectorAll('[data-provider-filter]')];
    let category = '全部';
    const update = () => {
      const query = input.value.trim().toLocaleLowerCase();
      let visible = 0;
      cards.forEach(card => {
        card.hidden = !(category === '全部' || card.dataset.category === category) || !card.dataset.search.toLocaleLowerCase().includes(query);
        if (!card.hidden) visible++;
      });
      document.querySelector('#provider-count').textContent = `${visible}种接入入口`;
      document.querySelector('#provider-empty').hidden = visible !== 0;
    };
    filters.forEach(button => button.addEventListener('click', () => {
      category = button.dataset.providerFilter;
      filters.forEach(item => item.setAttribute('aria-pressed', String(item === button))); update();
    }));
    input.addEventListener('input', update);
    document.querySelector('[data-provider-reset]')?.addEventListener('click', () => {
      category = '全部'; input.value = '';
      filters.forEach(item => item.setAttribute('aria-pressed', String(item.dataset.providerFilter === category)));
      update(); input.focus();
    });
  }

  /** 数字比较版本，避免2.10.0被排在2.9.0之前。 */
  function compareRelease(a, b) {
    const left = a.version.split('-')[0].split('.').map(Number), right = b.version.split('-')[0].split('.').map(Number);
    for (let i = 0; i < Math.max(left.length, right.length); i++) {
      const diff = (right[i] || 0) - (left[i] || 0); if (diff) return diff;
    }
    return (b.versionCode || 0) - (a.versionCode || 0) || b.releasedAt.localeCompare(a.releasedAt);
  }

  /** 校验Android发行身份及独立应用的备份恢复迁移方式。 */
  function validateMigration(release) {
    const hasValidPackage = typeof release.packageId === 'string' && /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$/.test(release.packageId);
    const isAndroidApk = release.platform === 'android' && (release.distribution || 'apk') === 'apk';
    if ('packageId' in release && (!hasValidPackage || !isAndroidApk)) throw new Error('Android包名必须对应有效APK发行');
    if ('migration' in release && (release.migration !== 'backup-restore' || !hasValidPackage || !isAndroidApk)) throw new Error('备份恢复迁移必须标明Android APK包名');
  }

  /** 拒绝错误、重复或不完整的发布记录，而不是生成失效下载按钮。 */
  function validateCatalogue(data) {
    if (data.schemaVersion !== 2 || !Array.isArray(data.platforms) || !Array.isArray(data.releases)) throw new Error('版本清单格式不正确');
    const ids = new Set(), platformIds = new Set(data.platforms.map(p => p.id));
    for (const release of data.releases) {
      validateMigration(release);
      if (!release.id || ids.has(release.id) || !platformIds.has(release.platform)) throw new Error('版本ID或平台不正确');
      if ('productName' in release && (typeof release.productName !== 'string' || !release.productName.trim())) throw new Error('发行产品名称不正确');
      if (!/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(release.version) || !['stable', 'beta'].includes(release.channel)) throw new Error('版本信息不完整');
      const distribution = release.distribution || 'apk';
      if ('checksumsUrl' in release && (!['apk', 'ipa'].includes(distribution) || release.checksumsUrl !== `https://nivo.8666886.xyz/downloads/SHA256SUMS-v${release.version}.txt`)) throw new Error('校验清单与发行版本不符');
      if (!['apk', 'ipa', 'app-store', 'testflight'].includes(distribution)) throw new Error('发行方式不支持');
      if (distribution === 'ipa' && !['signed', 'unsigned'].includes(release.signing)) throw new Error('IPA需要注明签名状态');
      if (release.signing === 'unsigned' && (distribution !== 'ipa' || release.platform !== 'ios')) throw new Error('未签名发行仅适用于iOS IPA');
      if (['apk', 'ipa'].includes(distribution) && (!/^[a-f\d]{64}$/i.test(release.sha256) || !Number.isInteger(release.sizeBytes) || release.sizeBytes <= 0)) throw new Error('安装文件信息不完整');
      safeUrl(release.downloadUrl); safeUrl(release.sourceUrl); safeUrl(release.notesUrl, true);
      ids.add(release.id);
    }
    return data;
  }

  /** 用原生DOM生成一个已验证的下载卡。 */
  function renderRelease(release) {
    const card = node('div', undefined, 'release-card');
    const heading = node('div', undefined, 'release-heading');
    const title = node('div'); title.append(node('p', `${release.platform === 'android' ? 'Android' : 'iOS'} ${release.channel === 'stable' ? '稳定版' : '测试版'}`, 'eyebrow'), node('h2', `${release.productName || 'Nivo Bot'} v${release.version}`));
    const distribution = release.distribution || 'apk';
    const isUnsigned = release.signing === 'unsigned';
    const method = isUnsigned ? '未签名IPA' : {apk:'正式签名', ipa:'IPA', 'app-store':'App Store', testflight:'TestFlight'}[distribution];
    heading.append(title, node('span', method, 'chip')); card.append(heading, node('p', release.summary, 'release-summary'));
    const facts = node('div', undefined, 'release-facts');
    [`${release.platform === 'android' ? 'Android' : 'iOS'} ${release.minimumOs}+`, release.architecture, release.versionCode ? `构建${release.versionCode}` : '', release.sizeBytes ? `${(release.sizeBytes / 1_000_000).toFixed(1)}MB` : '', release.releasedAt].filter(Boolean).forEach(value => facts.append(node('span', value)));
    card.append(facts);
    if (isUnsigned) {
      const installation = node('aside', undefined, 'callout');
      installation.append(node('h3', '安装前需要自行签名'), node('p', '这是未签名IPA，不能下载后直接安装到iPhone。需要使用自己的Apple开发签名与适用的安装工具重新签名；能否安装、签名有效期和可用权限取决于你的账户与签名方式。本文件没有TestFlight或App Store安装入口。'));
      installation.append(anchor('查看iOS安装说明', 'install.html', 'text-link', true)); card.append(installation);
    }
    if (release.platform === 'android' && release.migration === 'backup-restore') {
      const installation = node('aside', undefined, 'callout');
      installation.append(node('h3', '独立应用，先备份再迁移'), node('p', `此版Android使用包名${release.packageId}，作为独立应用安装，不能覆盖安装原包名应用，可与旧版并存。先在旧版导出备份，再安装新版并导入支持的内容。重新授权所需系统权限，模型凭证按实际恢复情况重新配置。部分数据需保留在旧版，查看迁移范围后再操作；请保留旧应用与原始备份。`));
      installation.append(anchor('查看迁移范围', 'install.html#android-migration', 'text-link', true)); card.append(installation);
    }
    const actions = node('div', undefined, 'actions');
    const downloadLabel = {apk:'下载APK', ipa:`下载${method}`}[distribution] || '打开官方安装入口';
    actions.append(anchor(downloadLabel, release.downloadUrl, 'button primary'), anchor('查看更新说明', release.notesUrl, 'text-link', true));
    card.append(actions);
    if (release.sha256) {
      const checksum = node('div', undefined, 'checksum'), copy = node('button', '复制校验和', 'copy-button');
      copy.type = 'button'; copy.dataset.copy = release.sha256; copy.setAttribute('aria-label', '复制安装文件SHA256');
      checksum.append(node('span', '安装文件 SHA256'), node('code', release.sha256), copy); card.append(checksum);
    }
    const links = node('div', undefined, 'release-links');
    links.append(anchor('本版对应源码', release.sourceUrl));
    if (release.sha256 && release.checksumsUrl) links.append(anchor('本版校验清单', release.checksumsUrl));
    card.append(links);
    return card;
  }

  /** 平台、渠道和版本联动；URL可分享且浏览器前进后退有效。 */
  function downloads() {
    if (!document.querySelector('[data-downloads]')) return;
    const platformTabs = [...document.querySelectorAll('[data-platform]')];
    const channel = document.querySelector('#release-channel'), version = document.querySelector('#release-version');
    const content = document.querySelector('#release-content'), historyTable = document.querySelector('#release-history');
    const message = document.querySelector('#release-message'), retry = document.querySelector('#release-retry');
    const fallback = document.querySelector('#release-fallback');
    let data = null, currentPlatform = 'android';
    const urlState = () => new URL(location.href).searchParams;
    const writeUrl = () => {
      const url = new URL(location.href); url.searchParams.set('platform', currentPlatform); url.searchParams.set('channel', channel.value);
      if (version.value) url.searchParams.set('version', version.value); else url.searchParams.delete('version');
      window.history.pushState(null, '', url);
    };
    const renderHistory = releases => {
      if (!historyTable) return;
      historyTable.replaceChildren();
      if (!releases.length) { historyTable.append(node('p', '这个平台暂时没有公开发行记录。', 'muted')); return; }
      const table = node('table'), head = node('thead'), headerRow = node('tr'), body = node('tbody');
      ['平台', '版本', '渠道', '发布日期', '详情'].forEach(label => headerRow.append(node('th', label))); head.append(headerRow);
      releases.forEach(release => {
        const row = node('tr');
        [release.platform === 'android' ? 'Android' : 'iOS', `v${release.version}${release.versionCode ? `（${release.versionCode}）` : ''}`, release.channel === 'stable' ? '稳定版' : '测试版', release.releasedAt].forEach(value => row.append(node('td', value)));
        const cell = node('td'); cell.append(anchor('更新说明', release.notesUrl, '', true)); row.append(cell); body.append(row);
      });
      table.append(head, body); historyTable.append(table);
    };
    const render = (preferred = '') => {
      const platform = data.platforms.find(item => item.id === currentPlatform) || data.platforms[0];
      currentPlatform = platform.id;
      platformTabs.forEach(tab => {
        const selected = tab.dataset.platform === currentPlatform;
        tab.setAttribute('aria-selected', String(selected)); tab.tabIndex = selected ? 0 : -1;
        const metadata = data.platforms.find(item => item.id === tab.dataset.platform);
        if (metadata && tab.querySelector('span')) tab.querySelector('span').textContent = metadata.status === 'available' ? '已发布' : '尚未公开发布';
      });
      content.setAttribute('aria-labelledby', `platform-${currentPlatform}`);
      const all = data.releases.filter(release => release.platform === currentPlatform).sort(compareRelease);
      const available = all.filter(release => channel.value === 'all' || release.channel === channel.value);
      const selected = available.find(release => release.id === preferred) || available[0];
      version.replaceChildren();
      available.forEach(release => { const option = node('option', `v${release.version}${release.versionCode ? `（${release.versionCode}）` : ''} · ${release.releasedAt}`); option.value = release.id; version.append(option); });
      version.disabled = available.length === 0;
      channel.disabled = platform.status !== 'available';
      content.replaceChildren();
      if (selected) {
        version.value = selected.id; content.append(renderRelease(selected));
        message.textContent = `${available.length}个可用版本 · ${selected.sha256 ? '提供安装包身份与SHA256信息' : '请按官方商店页面完成安装'}`;
      } else {
        const unpublished = platform.status !== 'available';
        const empty = node('div', undefined, 'unreleased');
        empty.append(node('span', unpublished ? '尚未公开发布' : '当前渠道暂无版本', 'chip'), node('h2', unpublished ? `${platform.name}，留一个位置。` : '换一个发行渠道看看。'), node('p', unpublished ? platform.message : '所选渠道暂无可下载版本，请切换稳定版或全部已发布版本。'));
        if (platform.progressUrl) empty.append(anchor('查看平台开发记录', platform.progressUrl, 'text-link'));
        content.append(empty); message.textContent = unpublished ? '当前没有可下载的公开版本。' : '所选渠道暂无版本，其他渠道仍可选择。';
      }
      renderHistory(all);
    };
    const restore = () => {
      const params = urlState(); currentPlatform = data.platforms.some(p => p.id === params.get('platform')) ? params.get('platform') : 'android';
      channel.value = ['stable', 'beta', 'all'].includes(params.get('channel')) ? params.get('channel') : 'stable'; render(params.get('version') || '');
    };
    const load = async () => {
      retry.hidden = true;
      const controller = new AbortController();
      const deadline = setTimeout(() => controller.abort(), 8000);
      try {
        const response = await fetch(new URL('releases.json', root), { cache: 'no-cache', signal: controller.signal });
        if (!response.ok) throw new Error('版本目录暂不可用');
        data = validateCatalogue(await response.json()); restore();
        if (fallback) fallback.hidden = true;
      } catch {
        data = null;
        message.textContent = '版本目录暂未加载。可以使用下方两平台的发行入口，或重试。'; retry.hidden = false;
        if (fallback) fallback.hidden = false;
        platformTabs.forEach(tab => { tab.disabled = true; }); channel.disabled = true; version.disabled = true;
      } finally {
        clearTimeout(deadline);
      }
      if (data) platformTabs.forEach(tab => { tab.disabled = false; });
    };
    platformTabs.forEach((tab, index) => {
      tab.addEventListener('click', () => { if (!data) return; currentPlatform = tab.dataset.platform; render(); writeUrl(); });
      tab.addEventListener('keydown', event => {
        if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
        event.preventDefault(); const target = platformTabs[(index + (event.key === 'ArrowRight' ? 1 : -1) + platformTabs.length) % platformTabs.length]; target.click(); target.focus();
      });
    });
    channel.addEventListener('change', () => { if (data) { render(); writeUrl(); } });
    version.addEventListener('change', () => { if (data) { render(version.value); writeUrl(); } });
    window.addEventListener('popstate', () => { if (data) restore(); });
    retry.addEventListener('click', load); load();
  }

  /** 剪贴板失败时给出可理解的手动操作提示。 */
  document.addEventListener('click', async event => {
    const button = event.target.closest('[data-copy]');
    if (!button) return;
    const label = button.textContent;
    try { await navigator.clipboard.writeText(button.dataset.copy); button.textContent = '已复制'; announce('已复制到剪贴板'); }
    catch { button.textContent = '请手动选择复制'; announce('浏览器未允许复制，请选择旁边的文字手动复制'); }
    setTimeout(() => { button.textContent = label; }, 2400);
  });

  navigation(); guideNavigation(); document.querySelectorAll('[data-story]').forEach(dayStory);
  document.querySelectorAll('[data-carousel]').forEach(carousel); providerSearch(); downloads();
})();
