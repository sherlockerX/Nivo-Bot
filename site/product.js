/* 产品页只运行本地示例，不发送模型请求或存储访客输入。 */
const menuButton = document.querySelector('.menu-button');
const navigation = document.querySelector('#navigation');
menuButton?.addEventListener('click', () => {
  const isOpen = menuButton.getAttribute('aria-expanded') !== 'true';
  menuButton.setAttribute('aria-expanded', String(isOpen));
  navigation.classList.toggle('is-open', isOpen);
});
navigation?.addEventListener('click', (event) => {
  if (event.target.closest('a')) {
    menuButton.setAttribute('aria-expanded', 'false');
    navigation.classList.remove('is-open');
  }
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && menuButton?.getAttribute('aria-expanded') === 'true') {
    menuButton.setAttribute('aria-expanded', 'false');
    navigation.classList.remove('is-open');
    menuButton.focus();
  }
});

const STEP_NAMES = ['chat', 'task', 'focus', 'reflect'];
const STEP_LABELS = ['主要聊天', '待办 · 今天', '专注 · 阅读', '生活碎片 · 今天'];
const STEP_CONTENT = {
  chat: `<div class="demo-conversation"><div class="bubble user">最近想读完一本书，帮我安排一个容易开始的计划。</div><div class="demo-assistant"><span class="avatar-mark">n.</span><div>先不用安排整个月。<br>今天读一章，记下一句你想留住的话。<br><br>我们把它放进「个人成长」，留出25分钟？</div></div><div class="demo-chips"><span>一个具体任务</span><span>一个小的开始</span></div></div>`,
  task: `<h3 class="demo-title">今天，先做这一件。</h3><p class="demo-subtitle">个人成长 / 阅读</p><div class="task-sample"><span class="check-ring"></span><div>读一章，留下一句笔记<small>今天 · 25分钟 · 可以从专注开始</small></div><span class="sample-status progress">进行中</span></div><div class="task-sample"><span class="check-ring">✓</span><div>选一本现在想读的书<small>今天早些时候</small></div><span class="sample-status">已完成</span></div><p class="demo-caption">分组和标签可复用，任务状态由你的实际行动决定。</p>`,
  focus: `<div class="demo-focus"><p>读一章，留下一句笔记</p><strong id="demo-clock" aria-label="示例倒计时">25:00</strong><div class="timer-actions"><button id="timer-toggle">开始示例计时</button><button id="timer-reset" aria-label="重置示例计时">重置</button></div><small>网页示例，不会写入App记录</small></div><p class="demo-caption">App中可以选择自己的背景，熄屏后继续同一次专注。</p>`,
  reflect: `<p class="demo-subtitle">今天 / 一段阅读之后</p><div class="reflection-card"><span class="tiny-label">生活碎片 · 示例</span><p>原来不必等到有很多时间，<br>才开始做一点喜欢的事。</p><div class="reflection-links"><span>◴ 阅读专注 · 25分钟</span><span>✓ 读完一章</span></div></div><p class="demo-caption">把任务、投入的时间和自己的感受，留在同一段记录里。</p>`,
};
let activeStep = 0;
let remainingSeconds = 1500;
let deadline = null;
let timerHandle = null;

/** 离开计时示例时暂停，避免不可见的计时继续占用资源。 */
function stopExampleTimer() {
  if (deadline !== null) remainingSeconds = Math.max(0, Math.ceil((deadline - performance.now()) / 1000));
  deadline = null;
  clearInterval(timerHandle);
  timerHandle = null;
}

/** 使用单调时钟计算剩余时间，页面后台节流不造成累计误差。 */
function renderTimer() {
  if (deadline !== null) remainingSeconds = Math.max(0, Math.ceil((deadline - performance.now()) / 1000));
  const clock = document.querySelector('#demo-clock');
  if (!clock) return;
  clock.textContent = `${String(Math.floor(remainingSeconds / 60)).padStart(2, '0')}:${String(remainingSeconds % 60).padStart(2, '0')}`;
  if (remainingSeconds === 0) stopExampleTimer();
  document.querySelector('#timer-toggle').textContent = deadline !== null ? '暂停示例' : remainingSeconds === 0 ? '再来一次' : remainingSeconds === 1500 ? '开始示例计时' : '继续示例';
}

/** 切换同一演示面板，同步键盘焦点与辅助技术状态。 */
function selectStep(index, shouldFocus = false) {
  stopExampleTimer();
  activeStep = index;
  document.querySelectorAll('[data-step]').forEach((tab, tabIndex) => {
    const isSelected = index === tabIndex;
    tab.setAttribute('aria-selected', String(isSelected));
    tab.tabIndex = isSelected ? 0 : -1;
    if (shouldFocus && isSelected) tab.focus();
  });
  const panel = document.querySelector('#workflow-panel');
  panel.setAttribute('aria-labelledby', `tab-${STEP_NAMES[index]}`);
  panel.innerHTML = STEP_CONTENT[STEP_NAMES[index]];
  document.querySelector('#demo-location').textContent = STEP_LABELS[index];
  document.querySelector('#next-step').innerHTML = index === 3 ? '再看一次 <span aria-hidden="true">↻</span>' : '看看下一步 <span aria-hidden="true">→</span>';
  if (index === 2) {
    renderTimer();
    document.querySelector('#timer-toggle').addEventListener('click', () => {
      if (deadline !== null) stopExampleTimer();
      else {
        if (remainingSeconds === 0) remainingSeconds = 1500;
        deadline = performance.now() + remainingSeconds * 1000;
        timerHandle = setInterval(renderTimer, 250);
      }
      renderTimer();
    });
    document.querySelector('#timer-reset').addEventListener('click', () => {
      stopExampleTimer(); remainingSeconds = 1500; renderTimer();
    });
  }
}
const tabs = [...document.querySelectorAll('[data-step]')];
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectStep(index));
  tab.addEventListener('keydown', (event) => {
    const destinations = { ArrowRight: (index + 1) % 4, ArrowDown: (index + 1) % 4, ArrowLeft: (index + 3) % 4, ArrowUp: (index + 3) % 4, Home: 0, End: 3 };
    if (event.key in destinations) { event.preventDefault(); selectStep(destinations[event.key], true); }
  });
});
if (tabs.length) {
  selectStep(0);
  document.querySelector('#next-step').addEventListener('click', () => selectStep((activeStep + 1) % 4));
}
window.addEventListener('pagehide', stopExampleTimer);

const downloadDialog = document.querySelector('#download-dialog');
downloadDialog?.querySelector('.dialog-close').addEventListener('click', () => downloadDialog.close());
downloadDialog?.addEventListener('click', (event) => {
  if (event.target === downloadDialog) {
    const box = downloadDialog.getBoundingClientRect();
    if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) downloadDialog.close();
  }
});

/** 下载地址只接受同源文件或HTTPS；未发布时明确提供源码入口。 */
async function loadRelease() {
  const button = document.querySelector('#download-button');
  if (!button) return;
  let downloadUrl = null;
  button.addEventListener('click', () => {
    if (downloadUrl) window.location.assign(downloadUrl);
    else downloadDialog.showModal();
  });
  const status = document.querySelector('#release-status');
  try {
    const embeddedRelease = document.querySelector('#local-release-data');
    let release;
    if (location.protocol === 'file:' && embeddedRelease) release = JSON.parse(embeddedRelease.textContent);
    else {
      const response = await fetch('release.json', { cache: 'no-cache' });
      if (!response.ok) throw new Error('Release metadata unavailable');
      release = await response.json();
    }
    const version = typeof release.version === 'string' ? release.version : '开发版本';
    if (release.downloadUrl && ['local-preview', 'public'].includes(release.channel)) {
      const url = new URL(release.downloadUrl, location.href);
      const isLocalFile = release.channel === 'local-preview' && location.protocol === 'file:' &&
        url.protocol === 'file:' && /^downloads\/[A-Za-z0-9_.-]+\.apk$/.test(release.downloadUrl);
      if (!isLocalFile && url.protocol !== 'https:' && !(url.origin === location.origin && /^https?:$/.test(url.protocol))) throw new Error('Invalid download URL');
      downloadUrl = url.href;
      status.textContent = release.channel === 'local-preview' ? `本地评审包 · v${version} · 沿用开发签名，尚未公开发布` : `v${version} · Android ${release.androidMinimum}+ · ${release.abi}`;
      button.textContent = release.channel === 'local-preview' ? '下载本地评审版 ↓' : '下载Android版 ↓';
      if (/^[a-f0-9]{64}$/i.test(release.sha256 || '')) {
        const checksum = document.createElement('details');
        checksum.innerHTML = '<summary>查看SHA256</summary><p></p>';
        checksum.querySelector('p').textContent = release.sha256;
        checksum.style.overflowWrap = 'anywhere';
        status.append(checksum);
      }
    } else status.textContent = `当前源码版本 v${version} · 公开安装包准备中`;
  } catch {
    status.textContent = '当前提供源码与构建指南，公开安装包尚未配置。';
  }
}
loadRelease();
