import { createCompanion } from './companion.js';

const post = (m) => window.webkit?.messageHandlers?.companion?.postMessage(m);
window.companion = createCompanion(document.getElementById('thread'), { post });
post({ type: 'ready' });
