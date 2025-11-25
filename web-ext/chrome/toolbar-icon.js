const prefersDarkQuery = window.matchMedia('(prefers-color-scheme: dark)');
function onThemeChange() {
  chrome.runtime.sendMessage({
    type: 'themeChange',
    theme: prefersDarkQuery.matches ? 'dark' : 'light'
  });
}
prefersDarkQuery.addEventListener('change', onThemeChange);
onThemeChange();
