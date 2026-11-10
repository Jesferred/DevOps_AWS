// Loaded as a blocking <script src> in <head> so the saved theme applies before
// first paint (an inline script would be blocked by the CSP).
try {
  var t = localStorage.getItem('theme');
  if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
} catch (e) {}
