// Timer helper for util.js: worker timers keep their timing when the tab is in the background.
onmessage = (e) => setTimeout(() => postMessage(e.data.id), e.data.ms);
