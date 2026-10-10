export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

export function needsConfirm(btn, prompt, ms = 4000) {
    if (btn.classList.contains("confirm")) return false;
    const label = btn.textContent;
    btn.classList.add("confirm");
    btn.textContent = prompt;
    setTimeout(() => {
        btn.classList.remove("confirm");
        btn.textContent = label;
    }, ms);
    return true;
}

export function linkToOptions(link) {
    link.addEventListener("click", (e) => {
        e.preventDefault();
        chrome.runtime.openOptionsPage();
    });
}
