import SwiftUI

// MARK: - EmojiCategory definition
struct EmojiCategory {
  let name: String
  let symbol: String
  let emojis: [String]
  
  init(name: String, emojis: [String]) {
    self.name = name
    self.symbol = emojis.first ?? "😀"
    self.emojis = emojis
  }
  
  init(name: String, symbol: String, emojis: [String]) {
    self.name = name
    self.symbol = symbol
    self.emojis = emojis
  }
}

extension View {
    func emojiPicker(
        isPresented: Binding<Bool>,
        onEmojiSelected: @escaping (String) -> Void
    ) -> some View {
        self.modifier(
            EmojiPickerViewModifier(
                isPresented: isPresented,
                onEmojiSelected: onEmojiSelected
            )
        )
    }
}

struct EmojiPickerViewModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onEmojiSelected: (String) -> Void
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                NavigationView {
                    CustomEmojiPickerView(
                        isPresented: $isPresented,
                        onEmojiSelected: onEmojiSelected
                    )
                }
                .presentationDragIndicator(.visible)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
            }
    }
}

struct CustomEmojiPickerView: View {
    @Binding var isPresented: Bool
    let onEmojiSelected: (String) -> Void
    
    private let emojiCategories: [EmojiCategory] = [
        .init(name: "Smileys & People", symbol: "😀", emojis: [
            "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂", "🙃", "😉", "😌", "😍", "🥰", "😘", "😗", "😙", "😚", "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🤩", "🥳", "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣", "😖", "😫", "😩", "🥺", "😢", "😭", "😤", "😠", "😡", "🤬", "🤯", "😳", "🥵", "🥶", "😱", "😨", "😰", "😥", "😓", "🤗", "🤔", "🤭", "🤫", "🤥", "😶", "😐", "😑", "😬", "🙄", "😯", "😦", "😧", "😮", "😲", "🥱", "😴", "🤤", "😪", "😵", "🤐", "🥴", "🤢", "🤮", "🤧", "😷", "🤒", "🤕"
        ]),
        .init(name: "Animals & Nature", symbol: "🐶", emojis: [
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🙈", "🙉", "🙊", "🐒", "🐔", "🐧", "🐦", "🐤", "🐣", "🐥", "🦆", "🦅", "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞", "🐜", "🦟", "🦗", "🕷", "🕸", "🦂", "🐢", "🐍", "🦎", "🦖", "🦕", "🐙", "🦑", "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳", "🐋", "🦈", "🐊", "🐅", "🐆", "🦓", "🦍", "🦧", "🐘", "🦛", "🦏", "🐪", "🐫", "🦒", "🦘", "🐃", "🐂", "🐄", "🐎", "🐖", "🐏", "🐑", "🦙", "🐐", "🦌", "🐕", "🐩", "🦮", "🐕‍🦺", "🐈", "🐓", "🦃", "🦚", "🦜", "🦢", "🦩", "🕊", "🐇", "🦝", "🦨", "🦡", "🦦", "🦥", "🐁", "🐀", "🐿", "🦔"
        ]),
        .init(name: "Food & Drink", symbol: "🍎", emojis: [
            "🍎", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈", "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒", "🌶", "🫑", "🌽", "🥕", "🫒", "🧄", "🧅", "🥔", "🍠", "🥐", "🥯", "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🧈", "🥞", "🧇", "🥓", "🥩", "🍗", "🍖", "🦴", "🌭", "🍔", "🍟", "🍕", "🫓", "🥪", "🥙", "🧆", "🌮", "🌯", "🫔", "🥗", "🥘", "🫕", "🥫", "🍝", "🍜", "🍲", "🍛", "🍣", "🍱", "🥟", "🦪", "🍤", "🍙", "🍚", "🍘", "🍥", "🥠", "🥮", "🍢", "🍡", "🍧", "🍨", "🍦", "🥧", "🧁", "🍰", "🎂", "🍮", "🍭", "🍬", "🍫", "🍿", "🍩", "🍪", "🌰", "🥜", "🍯"
        ]),
        .init(name: "Activities", symbol: "⚽", emojis: [
            "⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱", "🪀", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏", "🪃", "🥅", "⛳", "🪁", "🏹", "🎣", "🤿", "🥊", "🥋", "🎽", "🛹", "🛷", "⛸", "🥌", "🎿", "⛷", "🏂", "🪂", "🏋️‍♀️", "🏋️", "🏋️‍♂️", "🤼‍♀️", "🤼", "🤼‍♂️", "🤸‍♀️", "🤸", "🤸‍♂️", "⛹️‍♀️", "⛹️", "⛹️‍♂️", "🤺", "🤾‍♀️", "🤾", "🤾‍♂️", "🏌️‍♀️", "🏌️", "🏌️‍♂️", "🏇", "🧘‍♀️", "🧘", "🧘‍♂️", "🏄‍♀️", "🏄", "🏄‍♂️", "🏊‍♀️", "🏊", "🏊‍♂️", "🤽‍♀️", "🤽", "🤽‍♂️", "🚣‍♀️", "🚣", "🚣‍♂️", "🧗‍♀️", "🧗", "🧗‍♂️", "🚵‍♀️", "🚵", "🚵‍♂️", "🚴‍♀️", "🚴", "🚴‍♂️", "🏆", "🥇", "🥈", "🥉", "🏅", "🎖", "🏵", "🎗", "🎫", "🎟", "🎪", "🤹‍♀️", "🤹", "🤹‍♂️", "🎭", "🩰", "🎨", "🎬", "🎤", "🎧", "🎼", "🎵", "🎶", "🎹", "🥁", "🪘", "🎷", "🎺", "🪗", "🎸", "🪕", "🎻", "🎲", "♟", "🎯", "🎳", "🎮", "🎰", "🧩"
        ]),
        .init(name: "Travel & Places", symbol: "🌍", emojis: [
            "🌍", "🌎", "🌏", "🌐", "🗺", "🗾", "🧭", "🏔", "⛰", "🌋", "🗻", "🏕", "🏖", "🏜", "🏝", "🏞", "🏟", "🏛", "🏗", "🧱", "🪨", "🪵", "🛖", "🏘", "🏚", "🏠", "🏡", "🏢", "🏣", "🏤", "🏥", "🏦", "🏨", "🏩", "🏪", "🏫", "🏬", "🏭", "🏯", "🏰", "🗼", "🗽", "⛪", "🕌", "🛕", "🕍", "⛩", "🕋", "⛲", "⛺", "🌁", "🌃", "🏙", "🌄", "🌅", "🌆", "🌇", "🌉", "♨️", "🎠", "🎡", "🎢", "💈", "🎪", "🚂", "🚃", "🚄", "🚅", "🚆", "🚇", "🚈", "🚉", "🚊", "🚝", "🚞", "🚋", "🚌", "🚍", "🚎", "🚐", "🚑", "🚒", "🚓", "🚔", "🚕", "🚖", "🚗", "🚘", "🚙", "🛻", "🚚", "🚛", "🚜", "🏎", "🏍", "🛵", "🦽", "🦼", "🛺", "🚲", "🛴", "🛹", "🛼", "🚁", "🚟", "🚠", "🚡", "🛰", "🚀", "🛸", "🛫", "🛬", "🪂", "💺", "🛶", "⛵", "🚤", "🛥", "🛳", "⛴", "🚢", "⚓", "🪝", "⛽", "🚧", "🚨", "🚥", "🚦", "🛑", "🚏"
        ]),
        .init(name: "Objects", symbol: "📱", emojis: [
            "📱", "📲", "💻", "⌨️", "🖥", "🖨", "🖱", "🖲", "🕹", "🗜", "💽", "💾", "💿", "📀", "📼", "📷", "📸", "📹", "🎥", "📽", "🎞", "📞", "☎️", "📟", "📠", "📺", "📻", "🎙", "🎚", "🎛", "🧭", "⏱", "⏲", "⏰", "🕰", "⌛", "⏳", "📡", "🔋", "🔌", "💡", "🔦", "🕯", "🪔", "🧯", "🛢", "💸", "💵", "💴", "💶", "💷", "🪙", "💰", "💳", "💎", "⚖️", "🪜", "🧰", "🔧", "🔨", "⚒", "🛠", "⛏", "🪓", "🪚", "🔩", "⚙️", "🪤", "🧲", "🔫", "💣", "🧨", "🪓", "🔪", "🗡", "⚔️", "🛡", "🚬", "⚰️", "🪦", "⚱️", "🏺", "🔮", "📿", "🧿", "💈", "⚗️", "🔭", "🔬", "🕳", "🩹", "🩺", "💊", "💉", "🩸", "🧬", "🦠", "🧫", "🧪", "🌡", "🧹", "🧺", "🧻", "🚽", "🚰", "🚿", "🛁", "🛀", "🧼", "🪥", "🪒", "🧽", "🪣", "🧴", "🛎", "🔑", "🗝", "🚪", "🪑", "🛋", "🛏", "🛌", "🧸", "🖼", "🛍", "🛒", "🎁", "🎈", "🎏", "🎀", "🎊", "🎉", "🎎", "🏮", "🎐", "🧧", "✉️", "📩", "📨", "📧", "💌", "📥", "📤", "📦", "🏷", "📪", "📫", "📬", "📭", "📮", "📯", "📜", "📃", "📄", "📑", "🧾", "📊", "📈", "📉", "🗒", "🗓", "📆", "📅", "🗑", "📇", "🗃", "🗳", "🗄", "📋", "📁", "📂", "🗂", "🗞", "📰", "📓", "📔", "📒", "📕", "📗", "📘", "📙", "📚", "📖", "🔖", "🧷", "🔗", "📎", "🖇", "📐", "📏", "🧮", "📌", "📍", "✂️", "🖊", "🖋", "✒️", "🖌", "🖍", "📝", "✏️", "🔍", "🔎", "🔏", "🔐", "🔒", "🔓"
        ]),
        .init(name: "Symbols", symbol: "❤️", emojis: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟", "☮️", "✝️", "☪️", "🕉", "☸️", "✡️", "🔯", "🕎", "☯️", "☦️", "🛐", "⛎", "♈", "♉", "♊", "♋", "♌", "♍", "♎", "♏", "♐", "♑", "♒", "♓", "🆔", "⚛️", "🉑", "☢️", "☣️", "📴", "📳", "🈶", "🈚", "🈸", "🈺", "🈷️", "✴️", "🆚", "💮", "🉐", "㊙️", "㊗️", "🈴", "🈵", "🈹", "🈲", "🅰️", "🅱️", "🆎", "🆑", "🅾️", "🆘", "❌", "⭕", "🛑", "⛔", "📛", "🚫", "💯", "💢", "♨️", "🚷", "🚯", "🚳", "🚱", "🔞", "📵", "🚭", "❗", "❕", "❓", "❔", "‼️", "⁉️", "🔅", "🔆", "〽️", "⚠️", "🚸", "🔱", "⚜️", "🔰", "♻️", "✅", "🈯", "💹", "❇️", "✳️", "❎", "🌐", "💠", "Ⓜ️", "🌀", "💤", "🏧", "🚾", "♿", "🅿️", "🈳", "🈂️", "🛂", "🛃", "🛄", "🛅", "🚹", "🚺", "🚼", "⚧", "🚻", "🚮", "🎦", "📶", "🈁", "🔣", "ℹ️", "🔤", "🔡", "🔠", "🆖", "🆗", "🆙", "🆒", "🆕", "🆓", "0️⃣", "1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣", "🔟", "🔢", "#️⃣", "*️⃣", "⏏️", "▶️", "⏸", "⏯", "⏹", "⏺", "⏭", "⏮", "⏩", "⏪", "⏫", "⏬", "◀️", "🔼", "🔽", "➡️", "⬅️", "⬆️", "⬇️", "↗️", "↘️", "↙️", "↖️", "↕️", "↔️", "↪️", "↩️", "⤴️", "⤵️", "🔀", "🔁", "🔂", "🔄", "🔃", "🎵", "🎶", "➕", "➖", "➗", "✖️", "🟰", "♾", "💲", "💱", "™️", "©️", "®️", "〰️", "➰", "➿", "🔚", "🔙", "🔛", "🔝", "🔜", "✔️", "☑️", "🔘", "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫", "⚪", "🟤", "🔺", "🔻", "🔸", "🔹", "🔶", "🔷", "🔳", "🔲", "▪️", "▫️", "◾", "◽", "◼️", "◻️", "🟥", "🟧", "🟨", "🟩", "🟦", "🟪", "⬛", "⬜", "🟫", "🔈", "🔇", "🔉", "🔊", "🔔", "🔕", "📣", "📢", "👁‍🗨", "💬", "💭", "🗯", "♠️", "♣️", "♥️", "♦️", "🃏", "🎴", "🀄", "🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚", "🕛", "🕜", "🕝", "🕞", "🕟", "🕠", "🕡", "🕢", "🕣", "🕤", "🕥", "🕦", "🕧"
        ]),
        .init(name: "Flags", symbol: "🏁", emojis: [
            "🏁", "🚩", "🎌", "🏴", "🏳️", "🏳️‍🌈", "🏳️‍⚧️", "🏴‍☠️", "🇦🇨", "🇦🇩", "🇦🇪", "🇦🇫", "🇦🇬", "🇦🇮", "🇦🇱", "🇦🇲", "🇦🇴", "🇦🇶", "🇦🇷", "🇦🇸", "🇦🇹", "🇦🇺", "🇦🇼", "🇦🇽", "🇦🇿", "🇧🇦", "🇧🇧", "🇧🇩", "🇧🇪", "🇧🇫", "🇧🇬", "🇧🇭", "🇧🇮", "🇧🇯", "🇧🇱", "🇧🇲", "🇧🇳", "🇧🇴", "🇧🇶", "🇧🇷", "🇧🇸", "🇧🇹", "🇧🇻", "🇧🇼", "🇧🇾", "🇧🇿", "🇨🇦", "🇨🇨", "🇨🇩", "🇨🇫", "🇨🇬", "🇨🇭", "🇨🇮", "🇨🇰", "🇨🇱", "🇨🇲", "🇨🇳", "🇨🇴", "🇨🇵", "🇨🇷", "🇨🇺", "🇨🇻", "🇨🇼", "🇨🇽", "🇨🇾", "🇨🇿", "🇩🇪", "🇩🇬", "🇩🇯", "🇩🇰", "🇩🇲", "🇩🇴", "🇩🇿", "🇪🇦", "🇪🇨", "🇪🇪", "🇪🇬", "🇪🇭", "🇪🇷", "🇪🇸", "🇪🇹", "🇪🇺", "🇫🇮", "🇫🇯", "🇫🇰", "🇫🇲", "🇫🇴", "🇫🇷", "🇬🇦", "🇬🇧", "🇬🇩", "🇬🇪", "🇬🇫", "🇬🇬", "🇬🇭", "🇬🇮", "🇬🇱", "🇬🇲", "🇬🇳", "🇬🇵", "🇬🇶", "🇬🇷", "🇬🇸", "🇬🇹", "🇬🇺", "🇬🇼", "🇬🇾", "🇭🇰", "🇭🇲", "🇭🇳", "🇭🇷", "🇭🇹", "🇭🇺", "🇮🇨", "🇮🇩", "🇮🇪", "🇮🇱", "🇮🇲", "🇮🇳", "🇮🇴", "🇮🇶", "🇮🇷", "🇮🇸", "🇮🇹", "🇯🇪", "🇯🇲", "🇯🇴", "🇯🇵", "🇰🇪", "🇰🇬", "🇰🇭", "🇰🇮", "🇰🇲", "🇰🇳", "🇰🇵", "🇰🇷", "🇰🇼", "🇰🇾", "🇰🇿", "🇱🇦", "🇱🇧", "🇱🇨", "🇱🇮", "🇱🇰", "🇱🇷", "🇱🇸", "🇱🇹", "🇱🇺", "🇱🇻", "🇱🇾", "🇲🇦", "🇲🇨", "🇲🇩", "🇲🇪", "🇲🇫", "🇲🇬", "🇲🇭", "🇲🇰", "🇲🇱", "🇲🇲", "🇲🇳", "🇲🇴", "🇲🇵", "🇲🇶", "🇲🇷", "🇲🇸", "🇲🇹", "🇲🇺", "🇲🇻", "🇲🇼", "🇲🇽", "🇲🇾", "🇲🇿", "🇳🇦", "🇳🇨", "🇳🇪", "🇳🇫", "🇳🇬", "🇳🇮", "🇳🇱", "🇳🇴", "🇳🇵", "🇳🇷", "🇳🇺", "🇳🇿", "🇴🇲", "🇵🇦", "🇵🇪", "🇵🇫", "🇵🇬", "🇵🇭", "🇵🇰", "🇵🇱", "🇵🇲", "🇵🇳", "🇵🇷", "🇵🇸", "🇵🇹", "🇵🇼", "🇵🇾", "🇶🇦", "🇷🇪", "🇷🇴", "🇷🇸", "🇷🇺", "🇷🇼", "🇸🇦", "🇸🇧", "🇸🇨", "🇸🇩", "🇸🇪", "🇸🇬", "🇸🇭", "🇸🇮", "🇸🇯", "🇸🇰", "🇸🇱", "🇸🇲", "🇸🇳", "🇸🇴", "🇸🇷", "🇸🇸", "🇸🇹", "🇸🇻", "🇸🇽", "🇸🇾", "🇸🇿", "🇹🇦", "🇹🇨", "🇹🇩", "🇹🇫", "🇹🇬", "🇹🇭", "🇹🇯", "🇹🇰", "🇹🇱", "🇹🇲", "🇹🇳", "🇹🇴", "🇹🇷", "🇹🇹", "🇹🇻", "🇹🇼", "🇹🇿", "🇺🇦", "🇺🇬", "🇺🇲", "🇺🇳", "🇺🇸", "🇺🇾", "🇺🇿", "🇻🇦", "🇻🇨", "🇻🇪", "🇻🇬", "🇻🇮", "🇻🇳", "🇻🇺", "🇼🇫", "🇼🇸", "🇽🇰", "🇾🇪", "🇾🇹", "🇿🇦", "🇿🇲", "🇿🇼", "🏴󠁧󠁢󠁥󠁮󠁧󠁿", "🏴󠁧󠁢󠁳󠁣󠁴󠁿", "🏴󠁧󠁢󠁷󠁬󠁳󠁿"
        ])
    ]
    
    @State private var selectedCategoryIndex = 0
    @State private var searchText = ""
    
    private var filteredEmojis: [String] {
        if searchText.isEmpty {
            return emojiCategories[selectedCategoryIndex].emojis
        } else {
            return emojiCategories.flatMap { $0.emojis }.filter { emoji in
                // Simple search - could be enhanced with emoji descriptions
                searchText.lowercased().allSatisfy { char in
                    emoji.localizedCaseInsensitiveContains(String(char))
                }
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel", systemImage: "xmark") {
                    isPresented = false
                }
                
                Spacer()
                
                Text("Emoji")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Clear") {
                    isPresented = false
                }
                .opacity(0) // Hidden but maintains layout
            }
            .padding()
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search emojis", text: $searchText)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.systemGray6)
            .cornerRadius(10)
            .padding(.horizontal)
            
            // Category tabs (hidden during search)
            if searchText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(Array(emojiCategories.enumerated()), id: \.0) { (index: Int, category: EmojiCategory) in
                            VStack {
                                Text(category.symbol)
                                    .font(.title2)
                                
                                Text(category.name)
                                    .font(.caption2)
                                    .foregroundColor(selectedCategoryIndex == index ? .accentColor : .secondary)
                            }
                            .padding(.vertical, 8)
                            .onTapGesture {
                                selectedCategoryIndex = index
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
            }
            
            Divider()
            
            // Emoji grid - responsive layout
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: max(6, min(10, Int(geometry.size.width / 45)))), spacing: 4) {
                        ForEach(filteredEmojis, id: \.self) { emoji in
                            Button {
                                onEmojiSelected(emoji)
                                isPresented = false
                            } label: {
                                Text(emoji)
                                    .font(.title3)
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}
