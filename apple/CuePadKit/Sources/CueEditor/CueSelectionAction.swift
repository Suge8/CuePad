public struct CueSelectionAction {
    public var title: String
    public var image: CueImage?
    public var perform: @MainActor (String) -> Void

    public init(title: String, image: CueImage?, perform: @escaping @MainActor (String) -> Void) {
        self.title = title
        self.image = image
        self.perform = perform
    }
}
