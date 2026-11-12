import os, tempfile, unittest

import look


class Items(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        for name in ("clip.mp4", "still.png", "frame@2x.png", "notes.txt"):
            open(os.path.join(self.dir, name), "w").close()

    def tearDown(self):
        self.tmp.cleanup()

    def p(self, name):
        return os.path.join(self.dir, name)

    def test_a_plain_path_is_whole(self):
        [it] = look.parse_item(self.p("clip.mp4"))
        self.assertEqual((it["kind"], it["t"], it["a"]), ("video", None, None))

    def test_at_time_is_one_frame(self):
        [it] = look.parse_item(self.p("clip.mp4") + "@2.5")
        self.assertEqual((it["kind"], it["t"]), ("frame", 2.5))
        self.assertEqual(it["spec"], self.p("clip.mp4") + "@2.5")

    def test_hash_range_is_a_span(self):
        [it] = look.parse_item(self.p("clip.mp4") + "#1-3.5::take-off")
        self.assertEqual((it["kind"], it["a"], it["b"], it["caption"]), ("video", 1.0, 3.5, "take-off"))

    def test_a_range_must_run_forward(self):
        with self.assertRaisesRegex(look.Usage, "ends after it starts"):
            look.parse_item(self.p("clip.mp4") + "#3-1")

    def test_an_existing_name_with_at_is_a_path(self):
        [it] = look.parse_item(self.p("frame@2x.png"))
        self.assertEqual((it["kind"], it["t"]), ("image", None))

    def test_images_take_no_time(self):
        with self.assertRaisesRegex(look.Usage, "videos only"):
            look.parse_item(self.p("still.png") + "@1")

    def test_unknown_files_are_refused(self):
        with self.assertRaisesRegex(look.Usage, "not an image or video"):
            look.parse_item(self.p("notes.txt"))

    def test_missing_files_are_refused(self):
        with self.assertRaisesRegex(look.Usage, "no such file"):
            look.parse_item(self.p("gone.mp4") + "@1")

    def test_a_directory_is_its_media_in_order(self):
        names = [os.path.basename(i["path"]) for i in look.parse_item(self.dir)]
        self.assertEqual(names, ["clip.mp4", "frame@2x.png", "still.png"])

    def test_items_json_carries_captions(self):
        [it] = look.items_from_spec([{"path": self.p("clip.mp4"), "a": 1, "b": 2, "caption": "a: b :: c"}])
        self.assertEqual((it["a"], it["caption"]), (1.0, "a: b :: c"))


class Keys(unittest.TestCase):
    def test_each_answer_gets_a_free_distinct_letter(self):
        keys = look.answer_keys(["keep", "drop", "unsure", "ding"])
        self.assertEqual(len(set(keys)), 4)
        self.assertFalse(set(keys) & look.RESERVED)
        self.assertEqual(keys[:3], ["e", "d", "u"])  # k is reserved for moving


class Layout(unittest.TestCase):
    def test_fit_keeps_aspect_within_box(self):
        c, r = look.fit(1600, 900, 80, 40, 8, 16)
        self.assertEqual((c, r), (80, 22))
        c, r = look.fit(648, 810, 80, 20, 8, 16)
        self.assertEqual(r, 20)
        self.assertLessEqual(c, 80)

    def test_one_item_takes_the_area(self):
        self.assertEqual(look.choose_grid(1, 100, 40, 0.8, 8, 16)[:2], (1, 1))

    def test_portrait_items_go_side_by_side_in_a_wide_pane(self):
        self.assertEqual(look.choose_grid(3, 150, 40, 0.8, 8, 16)[:2], (3, 1))

    def test_landscape_items_stack_in_a_tall_pane(self):
        self.assertEqual(look.choose_grid(3, 60, 60, 16 / 9, 8, 16)[:2], (1, 3))

    def test_too_many_items_page(self):
        k = look.per_page(200, 80, 30, 1.0, 8, 16)
        self.assertLess(k, 200)
        self.assertIsNotNone(look.choose_grid(k, 80, 30, 1.0, 8, 16))


class Answers(unittest.TestCase):
    spec = {"id": "x", "question": "q?", "items": [
        {"spec": "a.mp4", "caption": "A"}, {"spec": "b.mp4@1", "caption": None}]}

    def test_answer_names_items_by_number_and_spec(self):
        a = look.build_answer(self.spec, "answered", {1}, None, [(0, 1.23456)], " ", 3.21)
        self.assertEqual(a["picked"], [{"n": 2, "item": "b.mp4@1", "caption": None}])
        self.assertEqual(a["marks"], [{"n": 1, "item": "a.mp4", "caption": "A", "t": 1.235}])
        self.assertIsNone(a["note"])
        self.assertEqual(a["seconds"], 3.2)

    def test_timeouts_read_as_units(self):
        self.assertEqual(look.parse_duration("9m"), 540)
        self.assertEqual(look.parse_duration("90"), 90)
        with self.assertRaises(look.Usage):
            look.parse_duration("soon")


if __name__ == "__main__":
    unittest.main()
