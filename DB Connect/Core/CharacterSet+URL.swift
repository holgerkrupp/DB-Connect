import Foundation

nonisolated extension CharacterSet {
    /// Characters safe to leave unescaped inside a query *value*.
    ///
    /// `.urlQueryAllowed` permits `&` and `=`, which would let a key value break out of its
    /// own parameter — so they are removed here.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}
