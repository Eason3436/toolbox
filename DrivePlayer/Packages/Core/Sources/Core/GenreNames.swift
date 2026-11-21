/// TMDB 的 zh-TW 類型名稱常常是簡體字（「动画・动作」），這裡用類型 id 換成繁體。
/// 類型 id 是 TMDB 固定的清單（電影 19 個、劇集另外 8 個）。
public enum GenreNames {
    public static let traditional: [Int: String] = [
        28: "動作", 12: "冒險", 16: "動畫", 35: "喜劇", 80: "犯罪", 99: "紀錄片",
        18: "劇情", 10751: "家庭", 14: "奇幻", 36: "歷史", 27: "恐怖", 10402: "音樂",
        9648: "懸疑", 10749: "愛情", 878: "科幻", 10770: "電視電影", 53: "驚悚",
        10752: "戰爭", 37: "西部",
        10759: "動作冒險", 10762: "兒童", 10763: "新聞", 10764: "實境",
        10765: "科幻奇幻", 10766: "肥皂劇", 10767: "脫口秀", 10768: "戰爭政治",
    ]

    /// 已經存成名稱的舊資料：簡體或英文名稱 → 繁體
    private static let byName: [String: String] = {
        var map: [String: String] = [
            "动作": "動作", "冒险": "冒險", "动画": "動畫", "喜剧": "喜劇", "纪录": "紀錄片",
            "纪录片": "紀錄片", "剧情": "劇情", "历史": "歷史", "音乐": "音樂", "悬疑": "懸疑",
            "爱情": "愛情", "电视电影": "電視電影", "惊悚": "驚悚", "战争": "戰爭",
            "动作冒险": "動作冒險", "儿童": "兒童", "新闻": "新聞", "真人秀": "實境",
            "科幻奇幻": "科幻奇幻", "肥皂剧": "肥皂劇", "脱口秀": "脫口秀",
            "战争政治": "戰爭政治", "战争与政治": "戰爭政治", "科幻与奇幻": "科幻奇幻",
            "Action": "動作", "Adventure": "冒險", "Animation": "動畫", "Comedy": "喜劇",
            "Crime": "犯罪", "Documentary": "紀錄片", "Drama": "劇情", "Family": "家庭",
            "Fantasy": "奇幻", "History": "歷史", "Horror": "恐怖", "Music": "音樂",
            "Mystery": "懸疑", "Romance": "愛情", "Science Fiction": "科幻", "TV Movie": "電視電影",
            "Thriller": "驚悚", "War": "戰爭", "Western": "西部",
            "Action & Adventure": "動作冒險", "Kids": "兒童", "News": "新聞", "Reality": "實境",
            "Sci-Fi & Fantasy": "科幻奇幻", "Soap": "肥皂劇", "Talk": "脫口秀",
            "War & Politics": "戰爭政治",
        ]
        for name in traditional.values { map[name] = name }
        return map
    }()

    public static func name(for genre: TMDBGenre) -> String {
        traditional[genre.id] ?? name(genre.name)
    }

    public static func name(_ stored: String) -> String {
        byName[stored] ?? stored
    }
}
