import csv
import json
import tempfile
import unittest
from pathlib import Path

from prepare_hamskad import COLUMNS, prepare, write_outputs


class PreparationTest(unittest.TestCase):
    def prepare_rows(self, rows):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        source = Path(directory.name) / "hamskad.csv"
        with source.open("w", encoding="utf-8-sig", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=COLUMNS)
            writer.writeheader()
            writer.writerows({**dict.fromkeys(COLUMNS, ""), **row} for row in rows)
        return source, prepare(source)

    def entries(self, manifest):
        return [entry for meaning in manifest["meanings"] for entry in meaning["entries"]]

    def test_alternatives_become_words_but_compound_numbers_and_phrases_stay_together(self):
        _, (manifest, review, report) = self.prepare_rows([
            {"Word": "रीसुर / लीसूर", "English": "Avalanche", "Hindi": "बर्फ की चट्टान"},
            {"Word": "नीश निज़ाऊ \nइद", "English": "Forty one"},
            {"Word": "कुल्मु; रन्नु, तोङमू", "English": "to strike"},
            {"Word": "उ,", "Meaning": "उले फूल"},
        ])
        words = [entry["forms"][0]["text"] for entry in self.entries(manifest)]
        self.assertEqual(words, ["रीसुर", "लीसूर", "नीश निज़ाऊ इद", "कुल्मु", "रन्नु", "तोङमू", "उ"])
        self.assertEqual(len(manifest["meanings"][0]["entries"]), 2)
        self.assertEqual(report["counts"]["split_source_rows"], 2)
        self.assertEqual(review, [])

    def test_duplicates_are_removed_without_merging_different_meanings_or_places(self):
        _, (manifest, _, report) = self.prepare_rows([
            {"Word": "शा / शा", "English": "Meat", "Village": "Sangla"},
            {"Word": "शा", "English": "meat", "Village": " sangla "},
            {"Word": "शा", "English": "Meat", "Village": "Ropa"},
            {"Word": "शा", "English": "Other meaning", "Village": "Sangla"},
        ])
        entries = self.entries(manifest)
        self.assertEqual(len(entries), 3)
        self.assertEqual(entries[0]["source_rows"], [2, 3])
        self.assertEqual(report["counts"]["duplicate_records_removed"], 2)
        self.assertEqual(report["counts"]["repeated_word_groups"], 1)
        self.assertEqual(len(manifest["meanings"]), 2)

    def test_unicode_duplicates_and_stable_ids_survive_reordering(self):
        rows = [{"Word": "बिज़ुल", "English": "Lightning"},
                {"Word": "बिज़ुल", "English": "Lightning"},
                {"Word": "ती", "English": "Water"}]
        _, (first, _, _) = self.prepare_rows(rows)
        _, (second, _, _) = self.prepare_rows(list(reversed(rows)))
        self.assertEqual(len(self.entries(first)), 2)
        self.assertEqual({entry["public_id"] for entry in self.entries(first)},
                         {entry["public_id"] for entry in self.entries(second)})

    def test_ambiguous_and_missing_rows_are_preserved_in_review(self):
        rows = [{"Word": "पाबांग 'ऊपरी पहाड़ियों में चरागाह'; पनांग 'गांव के पास चरागाह'",
                 "English": "Pasture"},
                {"Word": "गुद (Singular) गुदो (Plural)", "English": "Arm"},
                {"Word": "तिल/ स्तिल Singular तिलो Plural", "English": "Gums"},
                {"English": "Fog"}, {"Word": "ती"},
                {"Word": "Tree", "Meaning": "Bothang"},
                {"Word": "ँआ", "Meaning": "5"}]
        source, (manifest, review, report) = self.prepare_rows(rows)
        self.assertEqual(len(review), 7)
        self.assertEqual(manifest["meanings"], [])
        self.assertEqual(review[0]["Word"], rows[0]["Word"])
        self.assertEqual(review[0]["Source row"], 2)
        self.assertEqual(review[5]["Reason"], "possibly_swapped_word_and_meaning")
        output = source.parent / "output"
        write_outputs(output, manifest, review, report)
        with (output / "review.csv").open(encoding="utf-8-sig", newline="") as handle:
            self.assertEqual(list(csv.DictReader(handle))[0]["Word"], rows[0]["Word"])

    def test_meaning_column_keeps_both_languages_and_deduplicates_descriptions(self):
        _, (manifest, _, _) = self.prepare_rows([
            {"Word": "क्रा", "English": "Hair", "Hindi": "बाल", "Meaning": "बाल"},
            {"Word": "कोठांग प्या", "English": "Eurasian Hoopoe", "Meaning": "हुपहुप पक्षी"},
            {"Word": "निश", "Meaning": "2"},
            {"Word": "रंग", "Meaning": "Color"},
        ])
        descriptions = [entry["entry"]["definitions"] for entry in self.entries(manifest)]
        self.assertEqual(len(descriptions[0]), 2)
        self.assertEqual(descriptions[1][1], {"language": "hindi", "text": "हुपहुप पक्षी"})
        self.assertEqual(descriptions[2], [{"language": "english", "text": "2"}])
        self.assertEqual(descriptions[3], [{"language": "english", "text": "Color"}])

    def test_bad_headers_and_row_width_are_rejected(self):
        source, _ = self.prepare_rows([{"Word": "ती", "English": "Water"}])
        for content in ["Bad,Header\na,b\n", ",".join(COLUMNS) + "\nती,Water\n",
                        ",".join(COLUMNS) + "\nती,,Water,,,,extra\n"]:
            source.write_text(content, encoding="utf-8")
            with self.assertRaises(ValueError):
                prepare(source)

    def test_prepared_output_is_valid_json_and_csv_with_commas_inside_descriptions(self):
        source, (manifest, review, report) = self.prepare_rows([
            {"Word": "ती", "English": 'Water, a "liquid"', "Village": " Sangla "}])
        output = source.parent / "output"
        write_outputs(output, manifest, review, report)
        self.assertEqual(json.loads((output / "manifest.json").read_text()), manifest)
        with (output / "cleaned.csv").open(encoding="utf-8-sig", newline="") as handle:
            row = next(csv.DictReader(handle))
            self.assertEqual(json.loads(row["Definitions"])[0]["text"], 'Water, a "liquid"')
            self.assertEqual(row["Village"], "Sangla")


if __name__ == "__main__":
    unittest.main()
