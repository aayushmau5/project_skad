# Project Skad design direction

- **Status:** Canonical for interface and UX decisions
- **Last consolidated:** 2026-10-07
- **Product decisions:** [docs/product-decisions.md](docs/product-decisions.md)

This document defines how Project Skad should look, behave, and communicate. It is the source of truth for public, contribution, and moderator interfaces. It does not silently expand the v0 feature scope: `docs/product-decisions.md` and `docs/future.md` still decide whether a capability exists now or later. When an implementation conflicts with this document, either bring the implementation back into alignment or update this document deliberately with the new decision and its reason.

## Product character

Skad is a living community archive, not a generic dictionary, a social network, or a government portal. The interface should feel:

- calm, direct, and trustworthy;
- useful on an inexpensive phone and an interrupted connection;
- respectful of variation between villages and speakers;
- welcoming to people who do not consider themselves technically confident;
- efficient for moderators doing repeated, evidence-sensitive work.

The visual language is editorial rather than decorative: warm paper-like surfaces, dark readable type, restrained indigo for action, and a small apricot accent for contribution or attention. Cultural identity should come from language, recordings, examples, places, attribution, and community context—not ornamental motifs added by the interface.

## Actors and their promises

### 1. Resident or learner

This is the primary public actor. They may be using a low-end phone, have a slow connection, prefer Hindi, know a spoken word without knowing its spelling, or be unfamiliar with archive terminology.

Their primary tasks are to:

1. find a word by typing or speaking;
2. understand its meaning and pronunciation;
3. see which language, place, or variety a form belongs to;
4. decide whether the result is trustworthy;
5. contribute missing knowledge when they have it.

The interface promises:

- search before navigation or explanation;
- voice search alongside text search where supported;
- forgiving spelling and transliteration behavior;
- meaningful content without JavaScript;
- visible review, source, place, and update information;
- no assumption that one spelling or pronunciation is universal across Kinnaur.

### 2. Contributor

A contributor is often the same person as a resident. They may be sharing a word, correction, example, recording, or image from a phone. Contribution must feel like helping with one small thing, not completing a database form.

The interface promises:

- no account required for a public contribution;
- one clear task at a time;
- ordinary language instead of archival or linguistic jargon;
- optional identity unless a workflow genuinely requires it;
- explicit, plain-language permission for public media use;
- village or community context when pronunciation or local form varies;
- entered information preserved through validation and recoverable send failures;
- a clear receipt and explanation that review happens before publication.

### 3. Moderator or language expert

Moderators understand the system and need more density. Their work is to evaluate evidence, preserve variation, resolve duplicates, edit proposals, and publish responsibly.

The interface promises:

- a separate workspace from the public site;
- a compact queue and detail view on desktop;
- explicit separation between contributor material, the published record, and the proposed result;
- visible consent, community/place, source, media state, and possible duplicates;
- actions named by outcome: **Approve and publish**, **Ask for clarification**, or **Send to community reviewer**;
- no hiding important review evidence behind hover or decorative cards.

### 4. Community reviewer or elder (when this workflow is introduced)

This actor may review a single item sent by a moderator, sometimes with assistance or on a shared device. Do not expose the full moderator system when the task is only to confirm a form, pronunciation, meaning, or cultural context.

The interface promises one item, one question, enough context to answer, and a clear choice to confirm, disagree, or say they are unsure.

## Core experience model

The public and contribution experience should feel like one continuous path:

**Find → understand → notice what is missing → share what you know → receive confirmation**

The moderation experience is a different path:

**Triage → inspect evidence → compare → verify permission and context → decide → leave history**

Do not force both paths into one navigation model. Public pages are narrow, calm, and task-led. Moderator pages are wider, denser, and evidence-led.

## Design principles

### Put the task before the system

Lead with “What word are you looking for?” rather than an explanation of the archive. On contribution pages, lead with the specific thing being added. On moderator pages, lead with what needs a decision.

### Ask one thing at a time

Progressive steps are preferred to a long undifferentiated form. Show optional fields only when they help the current contribution type. Never make a contributor understand the data model.

### Show why a record can be trusted

Review status, date, community or place, attribution, and source matter more than badges or abstract scores. Trust information belongs near the content it qualifies.

### Preserve variation instead of flattening it

Village, community, dialect, spelling, and speaker variation must be labelled clearly. Avoid words such as “wrong” when “different form,” “local form,” or “needs confirmation” is more accurate.

### Make recovery obvious

Interrupted uploads, failed sends, and reconnecting states must say what happened and what the person can do next. Never clear entered data after a recoverable error. If persistent local drafts are introduced later, their saved state must be explicit.

### Keep the interface visually quiet

Use hierarchy, spacing, type, and thin rules. Avoid dashboards made from cards, oversized hero sections, pill-shaped controls, gradients, glass effects, decorative illustrations, and motion without a task purpose.

## Language and multilingual behavior

English and Hindi are interface languages. Archive content may use any supported language and must retain its own language metadata, script, direction, and transliteration.

- Keep a visible **हिंदी / English** switch in the header. It is a text control, not a flag icon or dropdown.
- On a fresh device, public and contribution pages start in Hindi. The moderator workspace may start in English. Remember the choice on that device.
- Switching interface language changes navigation, labels, help, validation, and status messages. It must not translate or rewrite archived content.
- A result can show its original form, transliteration, meaning, and language label together when each adds meaning.
- Do not mix English and Hindi inside one control label except for names, language names, or unavoidable specialist terms.
- Hindi copy must be written and reviewed as natural Hindi, not shipped as a literal machine translation of English.
- Allow extra width and line height for Devanagari. Never solve translation overflow by shrinking text below the base size.
- Every form field, empty state, error, upload state, and confirmation needs both interface-language versions before the feature is considered complete.

## Visual foundation

### Colour

The settled direction is **indigo and sand**, with apricot used sparingly.

| Token | Value | Use |
| --- | --- | --- |
| `--skad-paper` | `#F8F5EE` | Main reading and form surface |
| `--skad-surface` | `#FFFEFB` | Header, inputs, and raised workspace surfaces |
| `--skad-ink` | `#252431` | Primary text and strong neutral actions |
| `--skad-muted` | `#6E6B78` | Secondary text that remains readable |
| `--skad-line` | `#D8D3CA` | Dividers, input borders, and structure |
| `--skad-wash` | `#EDEAF2` | Page background and quiet selected regions |
| `--skad-action` | `#4B4F96` | Primary action, active navigation, focus identity |
| `--skad-action-soft` | `#E6E6F4` | Subtle active or selected background |
| `--skad-trust` | `#3F6C5C` | Reviewed, consented, saved, or verified states |
| `--skad-attention` | `#C26D3A` | Missing content, recording, and attention cues |

Rules:

- The theme is light only for v0.
- Indigo identifies action; it is not a decorative fill for large areas.
- Apricot is a small cue, not a second primary colour.
- Green always means trust, completion, permission, or verification.
- Error red must be reserved for errors and destructive outcomes.
- Never rely on colour alone; pair it with text, an icon, or a structural change.
- Text and controls must meet WCAG AA contrast against their actual background.
- No gradients. Avoid pure black and large fields of pure white.

### Typography

Do not add hosted fonts. They cost bandwidth and can fail on poor connections.

- UI and body: `system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`.
- Entry words and the most important page heading may use `Georgia, "Noto Serif Devanagari", serif` when available.
- Body text: 14–16 px depending on viewport and reading context.
- Editable controls on mobile: at least 16 px.
- Primary page heading: 24–26 px. Do not exceed 32 px in ordinary product pages.
- Supporting text: at least 12 px; essential text must not be treated as supporting text.
- Prefer weights 400 and 500. Use weight, size, and spacing deliberately; do not bold whole sections.

### Shape, borders, and elevation

- Controls are square or nearly square. Default radius is `0`; a native control may use up to `2px` when needed.
- Use one-pixel borders and horizontal rules for structure.
- Avoid card borders around every section. Most groups should be separated by spacing or a rule.
- A subtle shadow is allowed only for a bounded phone/form surface or the moderator workspace shell.
- Do not use rounded pills for navigation, status, filters, or buttons.
- Archive glossary rows use a small rounded language pill when **All** languages is selected, as explicitly requested for this page. This identifies the language of each word in a mixed list; language filters remain square.

### Spacing and size

Use a compact 4 px rhythm: `4, 8, 12, 16, 24, 32`.

- Desktop buttons may be 36–40 px high.
- Touch targets should be about 44 px high on coarse pointers even if the visible icon remains small.
- Public reading content should usually stay within 44–48 rem.
- Public contribution forms, suggestion receipts, and recovery pages fill the same content width as the public reading pages, within the 48 rem page shell. This keeps headings, fields, and section rules aligned across the public flow; on narrow screens they use the available width.
- Moderator workspaces may use the available desktop width.
- Avoid generous padding used only to make the product look “premium.” Space must clarify grouping or improve touch use.

### Icons and imagery

- Use the existing project icon component and a small, consistent outline style.
- Pair unfamiliar icons with visible text.
- Do not use icons as cultural decoration.
- Never autoplay audio or video.
- Load archive images only when needed and preserve useful alt text and attribution.

## Interaction patterns

### Header

Public header:

- Skad wordmark at the left;
- Hindi/English switch at the right;
- no full navigation menu on the primary mobile search view;
- contribution entry points appear in context and may also live in a compact menu on larger screens.

Moderator header:

- `SKAD / Moderator` identity;
- Workspace, Review queue, Words, and Concepts as compact text navigation;
- interface language and account actions at the end.

### Search

- Search is the dominant public control.
- Accept a word, likely spelling, transliteration, or meaning in one field.
- Put voice search next to the text field when recording is available.
- Do not require a language selection before searching. Language is a refinement, not a gate.
- Results show the form first, then language or variety, a short meaning, and why the result matched when useful.
- Empty results should invite a spelling retry, voice search, or contribution—not end with “No results.”

### Entry page

The entry page follows this reading order, agreed on 2026-10-07, so readers see the meaning before pronunciation and supporting record details after the word's context:

1. word or expression, with language, variety, place, and part of speech when known;
2. concise meaning;
3. listen action;
4. examples and translations;
5. usage;
6. cultural context;
7. other forms and spellings, followed by equivalents in other languages;
8. about this record, including review/source information;
9. contextual contribution actions.

Do not present every database field with equal weight. Missing information should become a specific invitation such as **Record this pronunciation** or **Add the form used in your village**.

### Contribution flow

Prefer three short stages:

1. **Choose what you know** — word, meaning, pronunciation, example, correction, or image.
2. **Share it with context** — the content plus only the fields needed for that contribution type.
3. **Confirm and send** — permission, what will be public, review expectation, and receipt.

For audio:

- make recording more prominent than file upload on mobile;
- show recording time and a playback opportunity before sending;
- ask for village or community;
- explain public use permission in one plain sentence;
- never imply that one recording represents every speaker.

For all contributions:

- preserve entered values after validation and recoverable send errors;
- show upload progress in text as well as visually;
- make retry possible without re-entering data;
- use **Send for review**, not a vague **Submit**;
- after success, show the receipt and what happens next.

### Moderator workspace

The login and workspace landing pages share the archive's serif page heading, warm surfaces, and thin section rules. Header, content, and footer align to the wide moderator shell. The login form fills its content area; landing-page actions use compact text rows with a short explanation of each task.

The **Review submissions** action shows a small count pill for all submissions still needing a decision, matching the review queue across all pages. Pending, in-review, and clarification-needed submissions count; completed decisions do not. An empty queue shows zero.

Concept management starts with search and an alphabetical, paginated list. Creation has its own page, which shows existing concepts while the moderator enters a name and links to their records. Forms use “Concept name” and “Notes,” with a short explanation that only moderators can see the notes. Exact name matches, ignoring case and surrounding whitespace, prevent accidental creation; related matches remain suggestions. Checking and creation also work without JavaScript and preserve the name and notes after errors.

Words are a first-class section in the moderator navigation and workspace landing page. Its searchable, alphabetical, paginated list supports language filters and opens each word's editor directly. Word editing returns to the word list; its related concept is a secondary link. Concepts group words by meaning and can also link to their editors.

Word pages allow editing spellings, all meanings, usage, cultural context, variety, and place. Related examples have a separate editor for the sentence, translations, and reviewed word links. A changed sentence requires another link check before saving; shared examples update everywhere. Recording and image details can be edited in place. Delete actions explain their reach and require a reason and confirmation. Published records are archived with moderator history, and search updates in the same transaction. Deleting a word returns to Words and keeps shared examples and the other words in its concept; a concept must be empty before deletion.

Meaning and translation rows use a compact **Remove** button. It removes the row from the current form while keeping other unsaved edits; **Save word** or **Save example** commits the change. The last meaning cannot be removed, because every word needs at least one meaning.

The example editor names the sentence's archive language separately from its translations. Translation languages use named choices for supported archive languages, English, and Hindi; new rows require an explicit choice. Interface language never supplies the content language. Existing language codes remain compatible and appear under their full language names.

The default desktop pattern is a two-pane workspace:

- a 240–280 px review queue on the left;
- the selected contribution and decision controls on the right.

The detail pane should show, in this order:

1. contribution type, content, and received time;
2. community/place, contributor identity if supplied, and permission;
3. submitted media or text;
4. current published record;
5. proposed result after approval;
6. duplicate or related-entry checks;
7. unresolved review checks;
8. decision actions.

Use thin dividers rather than nested cards. The primary decision button may be filled indigo. Clarification and escalation remain text actions. Destructive rejection requires a reason and explicit confirmation.

## States and feedback

Every feature must design these states, not only the happy path:

- initial;
- loading or processing;
- empty;
- partial data;
- offline or reconnecting;
- locally saved draft, when that deferred capability is introduced;
- upload interrupted;
- validation error;
- server error with retry;
- success and receipt;
- permission denied or media unavailable.

Status messages should answer: **What happened? Is my information safe? What can I do now?**

## Accessibility

- Use semantic HTML and native controls first.
- Every input has a visible label; placeholders are examples, not labels.
- Preserve keyboard order and visible browser focus.
- Dynamic status uses an appropriate live region without announcing every progress tick.
- Do not hide essential actions behind hover.
- Do not encode review state, language, or error using colour alone.
- Audio controls need an accessible name, visible duration, and adjacent text identifying the word, speaker context, and attribution where available.
- Respect reduced-motion preferences. No looping or decorative animation.
- Test English and Hindi at 200% zoom and at a 320 px viewport.

## Low-bandwidth behavior

The visual system must support the product budgets in `docs/product-decisions.md`.

- Essential reading, search results, forms, and receipts work as server-rendered HTML.
- No hosted fonts, trackers, background video, decorative high-resolution imagery, or UI library added only for appearance.
- Media is lazy and user-initiated.
- Enhancement must not make basic navigation depend on a persistent socket.
- Prefer one useful page over a skeleton screen followed by the same page.

## Voice and copy

Write like a helpful community archive, not a database administrator.

- Use direct verbs: **Search**, **Listen**, **Record**, **Send for review**, **Save for later**.
- Say what the system knows: **Reviewed by two community moderators**.
- Say what it does not know: **The Hamskad form has not been recorded yet**.
- Explain consequences before consent: **This recording may be heard publicly after review**.
- Avoid: canonical, payload, entity, ingestion, metadata, invalid input, and other system language on public pages.
- Moderator-only technical terms are acceptable when they make decisions more precise.

## Agent implementation contract

Before changing a user-facing surface, identify:

1. the actor;
2. their one primary task;
3. the likely device and connection;
4. the interface language and archive-content language;
5. the success, failure, and recovery states;
6. the trust or consent information that must remain visible.

Implementation rules:

- Reuse existing Phoenix components and native elements before adding abstractions or dependencies.
- Keep key DOM IDs stable and add unique IDs to new forms, controls, queues, and status regions.
- Do not introduce a new colour, radius, type scale, card style, or navigation pattern for one page.
- Do not add an account requirement to public contribution flows without a product decision.
- Do not omit Hindi because a feature is “internal” unless it is truly moderator-only.
- Do not merge public and moderator information architecture.
- Any deliberate exception to this guide must be explained in the change and, if permanent, recorded here.

## Review checklist

A user-facing change is not complete until the reviewer can answer yes to all relevant questions:

- Is the intended actor and primary task obvious within a few seconds?
- Is the public path usable on a narrow phone without horizontal scrolling?
- Is the moderator path compact enough for repeated work?
- Are English and Hindi states complete and natural?
- Does archive content keep its own language and direction metadata?
- Are source, place, review, attribution, and permission shown where they affect trust?
- Are controls compact, square, and consistently styled?
- Is the indigo-and-sand palette used according to the token roles above?
- Are empty, offline, interrupted, error, and success states handled?
- Does useful content remain available without JavaScript?
- Are focus, labels, contrast, zoom, and touch targets accessible?
- Has the page avoided decorative cards, oversized text, unnecessary imagery, and new dependencies?
