<script setup lang="ts">
// 导航展示本分支仓库与star数；独立缓存键避免读取上游项目的旧计数。
import { onMounted, ref } from 'vue'
import { useData } from 'vitepress'

const REPO = 'https://github.com/sherlockerX/Nivo-Bot'
const API = 'https://api.github.com/repos/sherlockerX/Nivo-Bot'
const KEY = 'nivo-bot-stars'
const TTL = 3600000

const { lang } = useData()
const stars = ref('')

function fmt(n: number): string {
  if (n < 1000) return String(n)
  const k = (n / 1000).toFixed(n < 10000 ? 1 : 0)
  return k.replace(/\.0$/, '') + 'k'
}

function show(n: unknown) {
  if (typeof n === 'number' && n >= 0) stars.value = fmt(n)
}

onMounted(() => {
  let cached: { n?: unknown; t?: number } | null = null
  try {
    cached = JSON.parse(localStorage.getItem(KEY) || 'null')
  } catch {
    cached = null
  }
  const fresh = cached && typeof cached.n === 'number' && Date.now() - (cached.t || 0) < TTL
  if (cached && typeof cached.n === 'number') show(cached.n)
  if (fresh || typeof fetch !== 'function') return
  fetch(API, { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : null))
    .then((j) => {
      if (!j || typeof j.stargazers_count !== 'number') return
      show(j.stargazers_count)
      try {
        localStorage.setItem(KEY, JSON.stringify({ n: j.stargazers_count, t: Date.now() }))
      } catch {
        /* private mode */
      }
    })
    .catch(() => {
      /* no number, still GitHub */
    })
})
</script>

<template>
  <a
    class="NmGitHubStars"
    :href="REPO"
    target="_blank"
    rel="noopener"
    :aria-label="lang.startsWith('zh') ? 'Nivo Bot的GitHub仓库' : 'Nivo Bot on GitHub'"
  >
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" aria-hidden="true">
      <path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1.1 5.9L12 16.9l-5.3 2.8 1.1-5.9-4.3-4.1 5.9-.8z" />
    </svg>
    <span class="label">GitHub</span>
    <span class="n">{{ stars }}</span>
  </a>
</template>

<style scoped>
.NmGitHubStars {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  margin-left: 12px;
  height: var(--vp-nav-height);
  font-size: 13px;
  font-weight: 500;
  color: var(--vp-c-text-1);
  white-space: nowrap;
  transition: color 0.25s;
}

.NmGitHubStars:hover {
  color: var(--vp-c-brand-1);
}

.NmGitHubStars svg {
  width: 15px;
  height: 15px;
  flex: none;
}

.NmGitHubStars .n {
  display: inline-block;
  min-width: 2.6em;
  font-variant-numeric: tabular-nums;
  color: var(--vp-c-text-2);
}

@media (max-width: 767px) {
  .NmGitHubStars { margin-left: 4px; }
  .NmGitHubStars .label { display: none; }
  .NmGitHubStars .n { min-width: 0; }
}
</style>
