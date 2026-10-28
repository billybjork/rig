# What a red part says (Gate.Digest). A suite's log (it lists failures as
# "  1) test ..."): each failing test's lines up to its code or stacktrace,
# at most six, then the suite's result line. Anything else: the project's
# own diagnostics (a warning or error with its lib/, test/, config/, priv/
# or assets/ location; dependencies' are noise), Mix errors and the
# unformatted files under them, which precommit checks failed, credo
# issues, dialyzer's short lines, audit findings and TypeScript errors.
suite && /^  [0-9]+\) / { inblock = 1; kept = 0; frames = 0 }
suite && inblock && /^ *stacktrace:/ { inblock = 0; frames = 1; first = ""; next }
suite && frames && /^ +(test|lib)\/[^ ]+:[0-9]+:.*\(test\)$/ { print; frames = 0; next }
suite && frames && /^ +(test|lib)\/[^ ]+:[0-9]+/ { if (first == "") first = $0; next }
suite && frames && /^ *$/ { if (first != "") print first; frames = 0; next }
suite && inblock && /^ *$/ { next }
suite && inblock { if (kept++ < 6) print; next }
suite && /^[0-9]+ doctests?, [0-9]+ tests?, |^[0-9]+ tests?, |^Result:|^Failed:/ { print }
suite { next }
/^ *(warning|error):/ { said = $0; next }
/└─ (lib|test|config|priv|assets)\// { if (said != "") print said; print; said = ""; next }
/^<== .* failed in |^\*\* \(|^ +\* [^ ]+$|^ *┃ +\[|^ *┃ +[^ ]+:[0-9]+|^(lib|test)\/[^ ]+:[0-9]+:|^Name +|^Version +|^Title +|[0-9]+ errors? found|error TS[0-9]+/ { print }
