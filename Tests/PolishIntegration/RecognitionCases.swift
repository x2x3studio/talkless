// Chinese ASR error correction: accent confusions, homophones, phonetic English terms,
// dictionary terms, and guards against over-correction. Inputs are synthetic.
@MainActor
let recognitionCases: [PolishCase] = [
    PolishCase(
        name: "asr-accent-n-l",
        input: "\u{660E}\u{5929}\u{4E0B}\u{5348}\u{6211}\u{4EEC}\u{53BB}\u{516C}\u{53F8}\u{697C}\u{4E0B}\u{7684}\u{62FF}\u{5BB6}\u{5E97}\u{4E70}\u{6D41}\u{5976}\u{FF0C}\u{987A}\u{4FBF}\u{5E26}\u{70B9}\u{9762}\u{5305}\u{3002}",
        checks: [containsAll(["\u{90A3}\u{5BB6}", "\u{725B}\u{5976}", "\u{9762}\u{5305}"]), excludes(["\u{6D41}\u{5976}", "\u{62FF}\u{5BB6}"])]
    ),
    PolishCase(
        name: "asr-accent-retroflex",
        input: "\u{6211}\u{4EEC}\u{9700}\u{8981}\u{68EE}\u{8BF7}\u{66F4}\u{591A}\u{7684}\u{670D}\u{52A1}\u{5668}\u{77E5}\u{6E90}\u{FF0C}\u{4E0B}\u{5468}\u{4E00}\u{4E4B}\u{524D}\u{628A}\u{62A5}\u{544A}\u{4EA4}\u{4E0A}\u{53BB}\u{3002}",
        checks: [containsAll(["\u{7533}\u{8BF7}", "\u{8D44}\u{6E90}", "\u{4E0B}\u{5468}\u{4E00}", "\u{62A5}\u{544A}"]), excludes(["\u{68EE}\u{8BF7}", "\u{77E5}\u{6E90}"])]
    ),
    PolishCase(
        name: "asr-accent-nasal",
        input: "\u{4ECA}\u{5929}\u{7684}\u{4F1A}\u{8BAE}\u{6C14}\u{6C1B}\u{5F88}\u{5E73}\u{8FDB}\u{FF0C}\u{5927}\u{5BB6}\u{5BF9}\u{65B0}\u{65B9}\u{6848}\u{7684}\u{8BA4}\u{8BC6}\u{4E5F}\u{6BD4}\u{8F83}\u{4E00}\u{81F3}\u{3002}",
        checks: [containsAll(["\u{5E73}\u{9759}", "\u{4E00}\u{81F4}"]), excludes(["\u{5E73}\u{8FDB}", "\u{4E00}\u{81F3}"])]
    ),
    PolishCase(
        name: "asr-homophone-zai",
        input: "\u{6211}\u{518D}\u{5BB6}\u{91CC}\u{7B49}\u{4F60}\u{FF0C}\u{4F60}\u{5230}\u{4E86}\u{4EE5}\u{540E}\u{5728}\u{7ED9}\u{6211}\u{6253}\u{4E2A}\u{7535}\u{8BDD}\u{3002}",
        checks: [containsAll(["\u{5728}\u{5BB6}\u{91CC}", "\u{518D}\u{7ED9}\u{6211}"]), excludes(["\u{6211}\u{518D}\u{5BB6}\u{91CC}"])]
    ),
    PolishCase(
        name: "asr-accent-f-h",
        input: "\u{8FD9}\u{5F20}\u{82B1}\u{7968}\u{9700}\u{8981}\u{8D22}\u{52A1}\u{76D6}\u{7AE0}\u{FF0C}\u{9EBB}\u{70E6}\u{4F60}\u{56DE}\u{5934}\u{5E2E}\u{6211}\u{62A5}\u{6D88}\u{4E00}\u{4E0B}\u{3002}",
        checks: [containsAll(["\u{53D1}\u{7968}", "\u{62A5}\u{9500}"]), excludes(["\u{82B1}\u{7968}", "\u{62A5}\u{6D88}"])]
    ),
    PolishCase(
        name: "asr-english-term",
        input: "\u{6211}\u{4EEC}\u{524D}\u{7AEF}\u{7528}\u{745E}\u{827E}\u{514B}\u{7279}\u{5199}\u{FF0C}\u{4EE3}\u{7801}\u{7EDF}\u{4E00}\u{63D0}\u{4EA4}\u{5230}\u{5409}\u{7279}\u{54C8}\u{5E03}\u{4E0A}\u{3002}",
        checks: [containsAll(["React", "GitHub"]), excludes(["\u{745E}\u{827E}\u{514B}\u{7279}", "\u{5409}\u{7279}\u{54C8}\u{5E03}"])]
    ),
    PolishCase(
        name: "asr-dictionary-term",
        input: "\u{4E0B}\u{4E2A}\u{7248}\u{672C}\u{7684}\u{6258}\u{514B}\u{52D2}\u{65AF}\u{4F1A}\u{652F}\u{6301}\u{79BB}\u{7EBF}\u{8BC6}\u{522B}\u{3002}",
        dictionary: ["Talkless"],
        checks: [containsAll(["Talkless", "\u{79BB}\u{7EBF}\u{8BC6}\u{522B}"]), excludes(["\u{6258}\u{514B}\u{52D2}\u{65AF}"])]
    ),
    PolishCase(
        name: "asr-near-sound-word",
        input: "\u{8FD9}\u{4E2A}\u{529F}\u{80FD}\u{7684}\u{89C6}\u{7528}\u{7387}\u{5F88}\u{9AD8}\u{FF0C}\u{4F46}\u{662F}\u{7528}\u{6237}\u{53CD}\u{6E83}\u{8BF4}\u{6309}\u{94AE}\u{592A}\u{5C0F}\u{4E86}\u{3002}",
        checks: [containsAny(["\u{4F7F}\u{7528}\u{7387}", "\u{9002}\u{7528}\u{7387}"]), containsAll(["\u{53CD}\u{9988}", "\u{6309}\u{94AE}"]), excludes(["\u{89C6}\u{7528}\u{7387}", "\u{53CD}\u{6E83}"])]
    ),
    PolishCase(
        name: "asr-numbers-kept",
        input: "\u{9884}\u{7B97}\u{63A7}\u{5236}\u{5728}\u{4E09}\u{4E07}\u{4E94}\u{5343}\u{5143}\u{4EE5}\u{5185}\u{FF0C}\u{5468}\u{65E0}\u{4E4B}\u{524D}\u{7ED9}\u{6211}\u{4E00}\u{4E2A}\u{521D}\u{6B65}\u{65B9}\u{6848}\u{3002}",
        checks: [containsAll(["\u{5468}\u{4E94}"]), containsAny(["\u{4E09}\u{4E07}\u{4E94}", "35000", "35,000", "3.5\u{4E07}"]), excludes(["\u{5468}\u{65E0}"])]
    ),
    PolishCase(
        name: "asr-guard-correct-text",
        input: "\u{4ED6}\u{8BF4}\u{7684}\u{8FD9}\u{4E2A}\u{5730}\u{65B9}\u{FF0C}\u{5176}\u{5B9E}\u{79BB}\u{6211}\u{4EEC}\u{516C}\u{53F8}\u{4E0D}\u{8FDC}\u{FF0C}\u{8D70}\u{8DEF}\u{5341}\u{5206}\u{949F}\u{5C31}\u{5230}\u{4E86}\u{3002}",
        checks: [containsAll(["\u{8FD9}\u{4E2A}\u{5730}\u{65B9}", "\u{79BB}\u{6211}\u{4EEC}\u{516C}\u{53F8}\u{4E0D}\u{8FDC}", "\u{5341}\u{5206}\u{949F}"])]
    ),
    PolishCase(
        name: "asr-guard-rare-term",
        input: "\u{8FD9}\u{4E2A}\u{7B97}\u{6CD5}\u{7684}\u{9C81}\u{68D2}\u{6027}\u{5F88}\u{91CD}\u{8981}\u{FF0C}\u{6211}\u{4EEC}\u{8981}\u{505A}\u{66F4}\u{591A}\u{7684}\u{6D88}\u{878D}\u{5B9E}\u{9A8C}\u{3002}",
        checks: [containsAll(["\u{9C81}\u{68D2}\u{6027}", "\u{6D88}\u{878D}\u{5B9E}\u{9A8C}"])]
    ),
    PolishCase(
        name: "asr-guard-names",
        input: "\u{8BF7}\u{628A}\u{4F1A}\u{8BAE}\u{7EAA}\u{8981}\u{53D1}\u{7ED9}\u{674E}\u{5B81}\u{548C}\u{5218}\u{5FF5}\u{FF0C}\u{6284}\u{9001}\u{7ED9}\u{5F20}\u{4F1F}\u{3002}",
        checks: [containsAll(["\u{674E}\u{5B81}", "\u{5218}\u{5FF5}", "\u{5F20}\u{4F1F}", "\u{4F1A}\u{8BAE}\u{7EAA}\u{8981}"])]
    ),
    PolishCase(
        name: "asr-mixed-cleanup-and-fix",
        input: "\u{55EF}\u{90A3}\u{4E2A}\u{6211}\u{4EEC}\u{4E0B}\u{5468}\u{8981}\u{53BB}\u{6DF1}\u{9547}\u{51FA}\u{5DEE}\u{FF0C}\u{7136}\u{540E}\u{7136}\u{540E}\u{4F4F}\u{7684}\u{9152}\u{5E97}\u{5DF2}\u{7ECF}\u{5B9A}\u{597D}\u{4E86}\u{3002}",
        checks: [containsAll(["\u{6DF1}\u{5733}", "\u{51FA}\u{5DEE}", "\u{9152}\u{5E97}"]), excludes(["\u{6DF1}\u{9547}", "\u{7136}\u{540E}\u{7136}\u{540E}"])]
    ),
    PolishCase(
        name: "asr-tech-identifier",
        input: "\u{628A}\u{8FD9}\u{4E2A} bug \u{4FEE}\u{4E00}\u{4E0B}\u{FF0C}\u{7136}\u{540E}\u{8DD1}\u{4E00}\u{4E0B}\u{5355}\u{5143}\u{4FA7}\u{8BD5}\u{FF0C}\u{786E}\u{8BA4} CI \u{80FD}\u{8FC7}\u{3002}",
        checks: [containsAll(["bug", "\u{5355}\u{5143}\u{6D4B}\u{8BD5}", "CI"]), excludes(["\u{5355}\u{5143}\u{4FA7}\u{8BD5}"])]
    ),
    PolishCase(
        name: "asr-homophone-chongxin",
        input: "\u{8FD9}\u{4E2A}\u{65B9}\u{6848}\u{9700}\u{8981}\u{4ECE}\u{65B0}\u{8BC4}\u{4F30}\u{4E00}\u{4E0B}\u{98CE}\u{9669}\u{FF0C}\u{518D}\u{51B3}\u{5B9A}\u{8981}\u{4E0D}\u{8981}\u{4E0A}\u{7EBF}\u{3002}",
        checks: [containsAll(["\u{91CD}\u{65B0}\u{8BC4}\u{4F30}", "\u{98CE}\u{9669}", "\u{4E0A}\u{7EBF}"]), excludes(["\u{4ECE}\u{65B0}"])]
    ),
    PolishCase(
        name: "asr-homophone-return-value",
        input: "\u{8BF7}\u{628A}\u{8FD9}\u{4E2A}\u{63A5}\u{53E3}\u{7684}\u{53CD}\u{56DE}\u{503C}\u{6539}\u{6210}\u{6570}\u{7EC4}\u{FF0C}\u{7A7A}\u{7684}\u{65F6}\u{5019}\u{8FD4}\u{56DE}\u{7A7A}\u{5217}\u{8868}\u{3002}",
        checks: [containsAll(["\u{8FD4}\u{56DE}\u{503C}", "\u{6570}\u{7EC4}", "\u{7A7A}\u{5217}\u{8868}"]), excludes(["\u{53CD}\u{56DE}\u{503C}"])]
    ),
    PolishCase(
        name: "asr-valid-word-sheji",
        input: "\u{6211}\u{4EEC}\u{8981}\u{628A}\u{8FD9}\u{6B21}\u{6539}\u{52A8}\u{8BBE}\u{8BA1}\u{5230}\u{7684}\u{6587}\u{4EF6}\u{90FD}\u{68C0}\u{67E5}\u{4E00}\u{904D}\u{3002}",
        checks: [containsAll(["\u{6D89}\u{53CA}\u{5230}", "\u{68C0}\u{67E5}\u{4E00}\u{904D}"]), excludes(["\u{8BBE}\u{8BA1}\u{5230}"])]
    ),
    PolishCase(
        name: "asr-valid-word-youxiang",
        input: "\u{9EBB}\u{70E6}\u{4F60}\u{628A}\u{8FD9}\u{4EFD}\u{5408}\u{540C}\u{53D1}\u{5230}\u{6211}\u{6CB9}\u{7BB1}\u{FF0C}\u{6211}\u{665A}\u{4E0A}\u{770B}\u{4E00}\u{4E0B}\u{3002}",
        checks: [containsAll(["\u{90AE}\u{7BB1}", "\u{5408}\u{540C}"]), excludes(["\u{6CB9}\u{7BB1}"])]
    ),
    PolishCase(
        name: "asr-homophone-meeting-room",
        input: "\u{4E0B}\u{5348}\u{4E09}\u{70B9}\u{5728}\u{4E09}\u{697C}\u{7684}\u{4F1A}\u{610F}\u{5BA4}\u{5F00}\u{4F1A}\u{FF0C}\u{8BB0}\u{5F97}\u{5E26}\u{4E0A}\u{7535}\u{8111}\u{3002}",
        checks: [containsAll(["\u{4F1A}\u{8BAE}\u{5BA4}", "\u{4E09}\u{70B9}", "\u{7535}\u{8111}"]), excludes(["\u{4F1A}\u{610F}\u{5BA4}"])]
    ),
    PolishCase(
        name: "asr-english-term-hard",
        input: "\u{670D}\u{52A1}\u{6700}\u{540E}\u{8981}\u{90E8}\u{7F72}\u{5230}\u{9177}\u{4F2F}\u{5185}\u{63D0}\u{65AF}\u{96C6}\u{7FA4}\u{4E0A}\u{FF0C}\u{955C}\u{50CF}\u{653E}\u{5728}\u{591A}\u{514B}\u{54C8}\u{5E03}\u{3002}",
        checks: [containsAll(["Kubernetes", "Docker Hub"]), excludes(["\u{9177}\u{4F2F}\u{5185}\u{63D0}\u{65AF}", "\u{591A}\u{514B}\u{54C8}\u{5E03}"])]
    ),
    PolishCase(
        name: "asr-guard-valid-literary",
        input: "\u{8FD9}\u{9996}\u{8001}\u{6B4C}\u{8BA9}\u{6211}\u{60F3}\u{8D77}\u{4E86}\u{90A3}\u{6BB5}\u{6D41}\u{5E74}\u{FF0C}\u{4E5F}\u{60F3}\u{8D77}\u{4E86}\u{5F53}\u{65F6}\u{4E00}\u{8D77}\u{62CD}\u{7167}\u{7559}\u{5FF5}\u{7684}\u{670B}\u{53CB}\u{3002}",
        checks: [containsAll(["\u{6D41}\u{5E74}", "\u{7559}\u{5FF5}", "\u{8001}\u{6B4C}"])]
    ),
]
