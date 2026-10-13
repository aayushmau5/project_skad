#!/usr/bin/env python3
"""Prepare the Hamskad spreadsheet for review and transactional import (stdlib only)."""

import argparse
import csv
import hashlib
import json
import re
import unicodedata
import uuid
from collections import Counter, defaultdict
from pathlib import Path


COLUMNS = ["Word", "Meaning", "English", "Hindi", "Village", "Region"]


def clean(text):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text)).strip()


def normalized(text):
    return clean(text).lower()


def identity(kind, value):
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"skad:hamskad:{kind}:{payload}"))


def definitions(row):
    values = [("english", row["English"]), ("hindi", row["Hindi"])]
    if row["Meaning"]:
        language = "hindi" if re.search(r"[\u0900-\u097f]", row["Meaning"]) else "english"
        values.append((language, row["Meaning"]))
    result = []
    seen = set()
    for language, text in values:
        key = (language, normalized(text))
        if text and key not in seen:
            result.append({"language": language, "text": text})
            seen.add(key)
    return result


def split_words(word):
    if re.search(r"[()\[\]{}'\"‘’“”]", word) or (
        re.search(r"[\u0900-\u097f]", word) and re.search(r"[a-zA-Z]", word)
    ):
        return [], "embedded_note_or_transliteration"
    # Spaces and line breaks can be part of expressions and compound numbers.
    parts = [clean(part) for part in re.split(r"[/;,]", word.rstrip("/;, "))]
    if not all(parts):
        return [], "empty_alternative"
    if any(unicodedata.category(part[0]).startswith("M") for part in parts):
        return [], "leading_combining_mark"
    return parts, None


def prepare(source):
    raw = source.read_bytes()
    with source.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, strict=True)
        if reader.fieldnames != COLUMNS:
            raise ValueError(f"Expected columns {COLUMNS}; got {reader.fieldnames}")
        original_rows = list(reader)
    if not original_rows:
        raise ValueError("CSV has no data rows")
    if any(set(row) != set(COLUMNS) or any(value is None for value in row.values())
           for row in original_rows):
        raise ValueError("CSV contains a row with the wrong number of columns")

    english_glosses = {normalized(row["English"]) for row in original_rows if row["English"]}
    meanings = {}
    entries = {}
    review = []
    duplicates = []
    stats = Counter(source_rows=len(original_rows))
    for source_row, original in enumerate(original_rows, 2):
        row = {key: clean(value) for key, value in original.items()}
        texts = definitions(row)
        words, reason = split_words(row["Word"]) if row["Word"] else ([], "missing_word")
        if not texts:
            reason = "missing_definition"
        if ((re.fullmatch(r"[A-Za-z ]+", row["Word"]) and
                normalized(row["Word"]) in english_glosses and not row["English"]) or
                # This source also contains an apparently inverted Tree / Bothang pair.
                (normalized(row["Word"]) == "tree" and normalized(row["Meaning"]) == "bothang")):
            reason = "possibly_swapped_word_and_meaning"
        if reason:
            review.append({"Source row": source_row, "Reason": reason, **original})
            continue

        stats["accepted_source_rows"] += 1
        stats["split_source_rows"] += len(words) > 1
        stats["normalized_whitespace_rows"] += original != row
        stats["meaning_language_inferred_rows"] += bool(row["Meaning"])
        definition_key = sorted((text["language"], normalized(text["text"])) for text in texts)
        concept_id = identity("concept", definition_key)
        meaning = meanings.setdefault(concept_id, {
            "public_id": concept_id,
            "concept": {"editorial_label": row["English"] or row["Hindi"] or row["Meaning"]},
            "entries": [],
        })
        for word in words:
            entry_attrs = {"definitions": texts, "place_label": row["Village"] or None,
                           "variety_label": row["Region"] or None}
            entry_id = identity("entry", [normalized(word), definition_key,
                                         normalized(row["Village"]), normalized(row["Region"])])
            if entry_id in entries:
                duplicates.append({"source_row": source_row, "word": word,
                                   "kept_source_row": entries[entry_id]["source_rows"][0]})
                if source_row not in entries[entry_id]["source_rows"]:
                    entries[entry_id]["source_rows"].append(source_row)
                continue
            entry = {"public_id": entry_id, "source_rows": [source_row], "entry": entry_attrs,
                     "forms": [{"text": word, "kind": "spelling", "is_primary": True}]}
            entries[entry_id] = entry
            meaning["entries"].append(entry)

    for meaning in meanings.values():
        rows = sorted({row for entry in meaning["entries"] for row in entry["source_rows"]})
        meaning["concept"]["editorial_note"] = (
            f"Imported from {source.name}; spreadsheet rows: " + ", ".join(map(str, rows)))

    by_word = defaultdict(list)
    for entry in entries.values():
        by_word[normalized(entry["forms"][0]["text"])].append(entry)
    repeated_words = [
        {"word": group[0]["forms"][0]["text"],
         "records": [{"source_rows": entry["source_rows"], **entry["entry"]} for entry in group]}
        for group in by_word.values() if len(group) > 1
    ]
    stats.update(review_rows=len(review), entries=len(entries), concepts=len(meanings),
                 duplicate_records_removed=len(duplicates), repeated_word_groups=len(repeated_words))
    manifest = {"version": 1, "source": {"filename": source.name,
                "sha256": hashlib.sha256(raw).hexdigest()},
                "language": {"slug": "hamskad", "name": "Hamskad", "direction": "ltr"},
                "meanings": list(meanings.values())}
    report = {"source": manifest["source"], "counts": dict(stats),
              "review_reasons": dict(Counter(row["Reason"] for row in review)),
              "duplicates": duplicates, "repeated_words": repeated_words}
    return manifest, review, report


def write_csv(path, columns, rows):
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def write_outputs(output, manifest, review, report):
    output.mkdir(parents=True, exist_ok=True)
    for filename, content in [("manifest.json", manifest), ("report.json", report)]:
        (output / filename).write_text(json.dumps(content, ensure_ascii=False, indent=2) + "\n",
                                      encoding="utf-8")
    write_csv(output / "review.csv", ["Source row", "Reason", *COLUMNS], review)
    cleaned = []
    for meaning in manifest["meanings"]:
        for entry in meaning["entries"]:
            attrs = entry["entry"]
            cleaned.append({"Word": entry["forms"][0]["text"],
                            "Definitions": json.dumps(attrs["definitions"], ensure_ascii=False),
                            "Village": attrs["place_label"], "Region": attrs["variety_label"],
                            "Source rows": ", ".join(map(str, entry["source_rows"]))})
    write_csv(output / "cleaned.csv", ["Word", "Definitions", "Village", "Region", "Source rows"],
              cleaned)
    counts = report["counts"]
    lines = ["# Hamskad ingestion review", "", f"Source: `{manifest['source']['filename']}`", "",
             "| Result | Count |", "| --- | ---: |"]
    lines += [f"| {key.replace('_', ' ')} | {value} |" for key, value in counts.items()]
    lines += ["", "## Rows held for review", "",
              "These rows are excluded from the manifest; their original values are in `review.csv`.", ""]
    lines += [f"- {reason}: {count}" for reason, count in report["review_reasons"].items()]
    lines += ["", "## Cleanup rules", "",
              "- Split `/`, `;`, and `,` alternatives into separate entries sharing a concept.",
              "- Preserve phrases; collapse whitespace and line breaks; normalize Unicode to NFC.",
              "- Remove only duplicates with the same word, descriptions, village, and region.",
              "- Keep different meanings and local contexts, including similarly spelled words.",
              "- Infer the Meaning column as Hindi when it contains Devanagari, otherwise English. "
              "Numbers remain literal; no descriptions are translated or invented.",
              "- Hold embedded notes, suspicious swapped columns, missing words/definitions, "
              "and leading combining marks for a person to review.",
              "- Source row numbers are spreadsheet records, starting with header row 1.", "",
              "`report.json` lists removed duplicates and repeated spellings with distinct meanings "
              "or contexts. Repeated spellings are kept; these groups need expert judgment before "
              "any further merging.", "",
              "Resolve held rows in a copy of the source CSV, then regenerate and rebuild the "
              "fresh database. Keep this entire output directory alongside the database for provenance.", ""]
    (output / "report.md").write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        manifest, review, report = prepare(args.source.expanduser())
        write_outputs(args.output, manifest, review, report)
    except (OSError, ValueError, csv.Error) as error:
        parser.exit(1, f"Preparation failed: {error}\n")
    print(json.dumps(report["counts"], indent=2))
    print(f"Review: {args.output / 'report.md'}")


if __name__ == "__main__":
    main()
