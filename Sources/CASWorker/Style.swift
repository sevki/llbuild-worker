/// The stylesheet every page shares: colour variables with a dark theme that
/// follows the reader's system setting, and the footer's styles.
let siteStyle: StaticString = """
    :root {
        color-scheme: light dark;
        --bg: #ffffff;
        --fg: #1a1a1a;
        --muted: #666666;
        --panel: #f5f5f5;
        --border: #e5e5e5;
        --flash: #ffe58a;
        --link: #0b62d6;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --bg: #121417;
            --fg: #e6e6e6;
            --muted: #9aa0a6;
            --panel: #1e2126;
            --border: #2e3238;
            --flash: #6b5600;
            --link: #6cb0ff;
        }
    }
    body {
        max-width: 640px;
        margin: 0 auto;
        padding: 2rem;
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        background: var(--bg);
        color: var(--fg);
    }
    a { color: var(--link); }
    small { color: var(--muted); }
    pre {
        overflow-x: auto;
        background: var(--panel);
        padding: 1rem;
    }
    .site-footer {
        text-align: center;
        padding: 1rem;
        color: var(--muted);
    }
    """
