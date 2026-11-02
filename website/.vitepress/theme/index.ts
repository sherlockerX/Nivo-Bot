// The default theme with the project site's colours and type (custom.css), and the
// repository link with its star count in the nav (GitHubStars.vue). Nothing else.
import { h } from 'vue'
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import GitHubStars from './GitHubStars.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  Layout: () => h(DefaultTheme.Layout, null, { 'nav-bar-content-after': () => h(GitHubStars) }),
} satisfies Theme
