const inspectOrSubmit = async () => {
    const unsupported = (reason, error = '') => ({kind: 'web', reason, error});
    if (location.origin !== 'https://portal.ulsu.ru') return unsupported('unsupported_origin');
    // Per-document evidence survives React replacing the entire modal/form. No secrets.
    const trackerKey = Symbol.for('SmartTable.maxResponse.v2');
    const tracker = window[trackerKey] ||= {
        documentId: `${Date.now()}-${Math.random()}`, revision: 0,
        waiting: false, sending: false, outcome: '', error: '',
    };
    const evidence = () => ({pending: tracker.waiting, responseRevision: tracker.revision,
        outcome: tracker.outcome});
    // Native UI deliberately covers WebKit. Zero layout rectangles are not proof
    // of a missing form. Check actual HTML controls, not fieldsets/layout boxes.
    const visible = e => {
        if (!e || e.matches(':disabled') || e.type === 'hidden') return false;
        for (let p = e; p; p = p.parentElement) {
            const style = getComputedStyle(p);
            if (p.hidden || style.display === 'none' || style.visibility === 'hidden') return false;
        }
        return true;
    };
    const controls = f => Array.from(f.elements).filter(e =>
        ['INPUT', 'SELECT', 'TEXTAREA'].includes(e.tagName) &&
        visible(e) && !['submit', 'button', 'reset'].includes(e.type));
    const submitters = f => Array.from(f.querySelectorAll('button, input[type="submit"]'))
        .filter(e => visible(e) && (e.type === 'submit' || !e.type));
    const safeAction = (f, b, expectedPath) => {
        try {
            const u = new URL(b?.getAttribute('formaction') || f.action, location.href);
            const method = b?.getAttribute('formmethod') || f.method;
            const target = b?.getAttribute('formtarget') || f.target;
            return u.origin === location.origin && !u.username && !u.password &&
                (!expectedPath || u.pathname === expectedPath) &&
                method.toLowerCase() === 'post' && (!target || target === '_self');
        } catch { return false; }
    };
    const message = (document.querySelector('#loginerrormessage, .loginerrors')?.textContent || '')
        .replace(/\s+/g, ' ').trim().slice(0, 320);
    // Actual MAX modal supplied in max.html: readonly aggregate, six controlled
    // digit inputs and a JS submit handler. There is no POST action or input name.
    const modal = document.querySelector('.loginwait-modal[role="dialog"]');
    if (modal) {
        const forms = modal.querySelectorAll('#loginwait-content form');
        const f = forms.length === 1 ? forms[0] : null;
        const aggregate = f?.querySelector('input#loginwait-code[autocomplete="one-time-code"][readonly]');
        const digits = f ? Array.from(f.querySelectorAll('input.loginwait-code-digit')) : [];
        const buttons = f ? f.querySelectorAll('button.loginwait-confirm-btn[type="submit"]') : [];
        const statusSelector = '.loginwait-invalid-code-msg, [role="alert"], [aria-live="assertive"], .loginwait-error';
        const statusText = () => (modal.querySelector(statusSelector)?.textContent || '').trim().slice(0, 320);
        const status = statusText();
        const maxSafe = () => {
            if (!f?.isConnected) return false;
            const aggregate = f.querySelector('input#loginwait-code[autocomplete="one-time-code"][readonly]');
            const digits = Array.from(f.querySelectorAll('input.loginwait-code-digit'));
            const buttons = f.querySelectorAll('button.loginwait-confirm-btn[type="submit"]');
            if (!aggregate || digits.length !== 6 || buttons.length !== 1) return false;
            if (f.hasAttribute('action') || f.hasAttribute('method') || f.hasAttribute('target')) return false;
            if (buttons[0].hasAttribute('formaction') || buttons[0].hasAttribute('formmethod')) return false;
            if (f.querySelector('iframe, .g-recaptcha, .h-captcha')) return false;
            return digits.every(e => e.type === 'text' && e.inputMode === 'numeric' &&
                !e.disabled && !e.readOnly && !e.name && e.form === f) &&
                Array.from(f.querySelectorAll('input,select,textarea')).every(e => e === aggregate || digits.includes(e));
        };
        // Official waitapp.js unmounts the form while verifying and on success.
        if (!f) return {...unsupported(tracker.outcome === 'accepted' ? 'max_accepted' : 'max_processing'),
            ...evidence(), error: tracker.error};
        if (!maxSafe()) return {...unsupported('max_form_changed', 'Изменилась форма подтверждения MAX.'), ...evidence()};
        if (mode === 'inspect') return {kind: 'code',
            error: tracker.waiting ? tracker.error : tracker.error || status, ...evidence()};
        if (tracker.waiting || tracker.sending) return {...evidence(), kind: 'code', pending: true};
        if (mode !== 'code') return {kind: 'web', error: 'Сейчас нужен код из MAX.'};
        if (!/^[0-9]{6}$/.test(code)) return {kind: 'code', error: 'Введите шесть цифр кода.'};
        tracker.sending = true;
        return (async () => {
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            for (let i = 0; i < 6; i++) {
                // Controlled components may render new input nodes after each event.
                const current = modal.querySelectorAll('input.loginwait-code-digit')[i];
                if (!current || !f.isConnected) return {kind: 'web', error: 'Форма кода изменилась.'};
                setter.call(current, code[i]);
                current.dispatchEvent(new Event('input', {bubbles: true, composed: true}));
                current.dispatchEvent(new Event('change', {bubbles: true}));
                await new Promise(resolve => setTimeout(resolve, 0));
            }
            for (let i = 0; i < 20; i++) {
                if (location.origin !== 'https://portal.ulsu.ru' || !f.isConnected) return {kind: 'web'};
                const button = f.querySelector('button.loginwait-confirm-btn[type="submit"]');
                const filled = Array.from(f.querySelectorAll('input.loginwait-code-digit')).map(e => e.value).join('');
                if (button && !button.disabled && filled === code) {
                    if (!maxSafe()) return {kind: 'web'};
                    // Dispatch only the event. Never invoke a default GET submission
                    // for this action-less form. Its own JS must cancel and handle it.
                    const event = new SubmitEvent('submit', {bubbles: true, cancelable: true, submitter: button});
                    // Observe only the official verification request started synchronously
                    // by this submit handler. Never send a request ourselves or retain its body.
                    const originalFetch = window.fetch;
                    const root = document.getElementById('loginwait-root');
                    const endpoints = ['apiVerifyUrl', 'apiVerifyStaticUrl'].flatMap(key => {
                        try {
                            const value = root?.dataset[key];
                            if (!value) return [];
                            const url = new URL(value, location.href);
                            return url.origin === location.origin && !url.username && !url.password ? [url.href] : [];
                        } catch { return []; }
                    });
                    tracker.waiting = true;
                    tracker.outcome = '';
                    tracker.error = '';
                    const responseRevision = tracker.revision;
                    let requests = 0;
                    const observedFetch = function(input, init) {
                        const promise = originalFetch.apply(this, arguments);
                        let matches = false;
                        try {
                            matches = (init?.method || input?.method || 'GET').toUpperCase() === 'POST' &&
                                endpoints.includes(new URL(typeof input === 'string' ? input : input.url, location.href).href);
                        } catch {}
                        if (matches) {
                            requests++;
                            // A clone leaves the site's response stream and handlers untouched.
                            Promise.resolve(promise).then(async response => {
                                if (!response.ok || response.redirected) return;
                                const data = await response.clone().json();
                                if (requests !== 1 || tracker.revision !== responseRevision || !tracker.waiting) return;
                                // The official bundle translates API error keys through this JSON.
                                let translated = '';
                                try {
                                    translated = JSON.parse(document.getElementById('loginwait-strings')?.textContent || '{}')
                                        .ru?.[data.error] || '';
                                } catch {}
                                if (data.success === true) {
                                    tracker.outcome = 'accepted'; // Still requires native session verification.
                                } else if (data.success === false &&
                                    (['invalid_code', 'Неверный или просроченный код'].includes(data.error) ||
                                        translated === 'Неверный или просроченный код')) {
                                    tracker.outcome = 'rejected';
                                    tracker.error = 'Неверный или просроченный код';
                                    tracker.waiting = false;
                                } else if (data.success === false && ['expired', 'disabled'].includes(data.error)) {
                                    tracker.outcome = 'expired';
                                    tracker.error = 'Срок действия подтверждения MAX истёк. Начните новый вход.';
                                } else return;
                                tracker.revision++;
                            }).catch(() => {}); // Unknown result must never permit resubmission.
                        }
                        return promise;
                    };
                    try {
                        if (typeof originalFetch === 'function') window.fetch = observedFetch;
                        f.dispatchEvent(event);
                    } finally {
                        if (window.fetch === observedFetch) window.fetch = originalFetch;
                    }
                    // Dispatch has occurred; even a broken handler is not proof of no request.
                    return {kind: 'code', submitted: true, responseRevision};
                }
                await new Promise(resolve => setTimeout(resolve, 50));
            }
            return {kind: 'code', error: 'MAX не принял ввод кода. Дождитесь загрузки формы и попробуйте снова.'};
        })().finally(() => { tracker.sending = false; });
    }
    // wait.php can already contain the user's header while MAX is still mounting.
    // That header must never start cookie verification before the challenge finishes.
    if (mode === 'inspect' && !location.pathname.endsWith('/wait.php') &&
        location.pathname !== '/login/index.php' &&
        !document.querySelector('form#login, input[name="logintoken"]') &&
        document.querySelector('.usermenu a[href*="/user/profile.php"]') &&
        document.querySelector('a[href*="/login/logout.php"]') &&
        document.querySelector('span.usertext')?.textContent.trim()) {
        // Only a hint to perform the protected account check, never proof of login.
        return {kind: 'authenticated'};
    }
    let form, fields, button, kind;
    if (location.pathname === '/login/index.php') {
        const forms = document.querySelectorAll('form#login');
        if (forms.length !== 1) return unsupported('login_form_missing', message);
        form = forms[0];
        const usernames = form.querySelectorAll('input#username[name="username"]');
        const passwords = form.querySelectorAll('input#password[name="password"][type="password"]');
        const tokens = form.querySelectorAll('input[name="logintoken"][type="hidden"]');
        const buttons = submitters(form);
        if (usernames.length !== 1 || passwords.length !== 1) return unsupported('login_fields_changed', message);
        if (tokens.length !== 1 || !tokens[0].value) return unsupported('login_token_missing', message);
        if (buttons.length !== 1 || buttons[0].id !== 'loginbtn') return unsupported('login_button_unavailable', message);
        fields = [usernames[0], passwords[0]];
        button = buttons[0];
        if (!fields.every(visible)) return unsupported('login_fields_unavailable', message);
        if (controls(form).some(e => !fields.includes(e))) return unsupported('additional_login_fields', message);
        if (form.querySelector('iframe, .g-recaptcha, .h-captcha')) return unsupported('interactive_challenge', message);
        if (new URL(form.action, location.href).pathname !== '/login/index.php') return unsupported('login_action_changed', message);
        kind = 'credentials';
    } else if (location.pathname.endsWith('/wait.php')) {
        // Do not guess a field called "code" or a hidden 2FA endpoint.
        const candidates = Array.from(document.querySelectorAll('input[autocomplete~="one-time-code"]'))
            .filter(visible);
        if (candidates.length !== 1 || !candidates[0].form) return unsupported('code_form_missing');
        fields = candidates;
        form = candidates[0].form;
        const buttons = submitters(form);
        if (buttons.length !== 1 || controls(form).some(e => e !== candidates[0]) ||
            form.querySelector('iframe, .g-recaptcha, .h-captcha')) return unsupported('code_form_changed');
        button = buttons[0];
        kind = 'code';
    } else return unsupported('unsupported_page');
    const expectedPath = kind === 'credentials' ? '/login/index.php' : null;
    if (!safeAction(form, button, expectedPath)) return unsupported('unsafe_form_action');
    if (mode === 'inspect') return {kind, error: message};
    if (mode !== kind) return {kind: 'web', error: 'Страница входа изменилась. Попробуйте войти ещё раз.'};
    if (kind === 'credentials' && (!username || !password)) return {kind, error: 'Введите логин и пароль.'};
    if (kind === 'code' && !/^[0-9]{6}$/.test(code)) return {kind, error: 'Введите шесть цифр кода.'};
    const values = kind === 'credentials' ? [username, password] : [code];
    fields.forEach((field, i) => {
        field.value = values[i];
        field.dispatchEvent(new Event('input', {bubbles: true}));
        field.dispatchEvent(new Event('change', {bubbles: true}));
    });
    if (!form.isConnected || !safeAction(form, button, expectedPath) || !form.checkValidity()) {
        return {kind: 'web', error: 'На странице требуется дополнительное действие.'};
    }
    HTMLFormElement.prototype.requestSubmit.call(form, button);
    return {kind, submitted: true};
};
const result = await inspectOrSubmit();
const tracker = window[Symbol.for('SmartTable.maxResponse.v2')];
if (tracker) result.documentId = tracker.documentId;
return JSON.stringify(result);

