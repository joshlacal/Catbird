import SwiftUI
import UIKit
import Petrel

// MARK: - Waterfall Layout

final class WaterfallLayout: UICollectionViewLayout {
    private let numberOfColumns: Int
    private let cellPadding: CGFloat
    private var cache: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var contentWidth: CGFloat {
        guard let collectionView = collectionView else { return 0 }
        let insets = collectionView.contentInset
        return collectionView.bounds.width - (insets.left + insets.right)
    }

    weak var delegate: WaterfallLayoutDelegate?

    init(numberOfColumns: Int = 2, cellPadding: CGFloat = 8) {
        self.numberOfColumns = numberOfColumns
        self.cellPadding = cellPadding
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth, height: contentHeight)
    }

    override func prepare() {
        guard let collectionView = collectionView, cache.isEmpty else { return }

        let columnWidth = contentWidth / CGFloat(numberOfColumns)
        var xOffset: [CGFloat] = []
        for column in 0..<numberOfColumns {
            xOffset.append(CGFloat(column) * columnWidth)
        }
        var column = 0
        var yOffset: [CGFloat] = .init(repeating: 0, count: numberOfColumns)

        for item in 0..<collectionView.numberOfItems(inSection: 0) {
            let indexPath = IndexPath(item: item, section: 0)

            let aspectRatio = delegate?.collectionView(collectionView, aspectRatioForItemAt: indexPath) ?? 1.0
            let photoWidth = columnWidth - cellPadding * 2
            let photoHeight = photoWidth / aspectRatio
            let height = cellPadding * 2 + photoHeight

            let frame = CGRect(
                x: xOffset[column],
                y: yOffset[column],
                width: columnWidth,
                height: height
            )
            let insetFrame = frame.insetBy(dx: cellPadding, dy: cellPadding)

            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = insetFrame
            cache.append(attributes)

            contentHeight = max(contentHeight, frame.maxY)
            yOffset[column] = yOffset[column] + height

            column = column < (numberOfColumns - 1) ? (column + 1) : 0
        }
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cache.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < cache.count else { return nil }
        return cache[indexPath.item]
    }

    override func invalidateLayout() {
        super.invalidateLayout()
        cache.removeAll()
        contentHeight = 0
    }
}

protocol WaterfallLayoutDelegate: AnyObject {
    func collectionView(_ collectionView: UICollectionView, aspectRatioForItemAt indexPath: IndexPath) -> CGFloat
}

// MARK: - Collection View Wrapper

struct GifWaterfallCollectionView: UIViewRepresentable {
    let gifs: [TenorGif]
    let isLoadingMore: Bool
    let onGifSelected: (TenorGif) -> Void
    let onLoadMore: () -> Void

    func makeUIView(context: Context) -> UICollectionView {
        let layout = WaterfallLayout(numberOfColumns: 2, cellPadding: 6)
        layout.delegate = context.coordinator

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.register(
            GifCollectionViewCell.self,
            forCellWithReuseIdentifier: GifCollectionViewCell.reuseIdentifier
        )
        collectionView.contentInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        return collectionView
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        let oldGifs = context.coordinator.gifs
        let oldCount = oldGifs.count
        let newCount = gifs.count
        
        // Debug: Check if data actually changed
        let dataChanged = oldGifs != gifs
        
        // Always update the loading state immediately  
        context.coordinator.isLoadingMore = isLoadingMore
        
        // Skip update if data hasn't changed
        guard dataChanged || oldCount != newCount else {
            return
        }
        
        // Check if this is a simple append operation (load more scenario)
        // Conditions: more items than before, had items before, and first oldCount items match exactly
        let isAppendOperation = newCount > oldCount && 
                                oldCount > 0 && 
                                Array(gifs.prefix(oldCount)) == oldGifs
        
        if isAppendOperation {
            // This is a load more - use batch insert for smooth animation
            // Update coordinator FIRST so it has the new data when cells are requested
            context.coordinator.gifs = gifs
            
            // Invalidate layout AFTER updating coordinator data
            if let layout = uiView.collectionViewLayout as? WaterfallLayout {
                layout.invalidateLayout()
            }
            
            let newIndexPaths = (oldCount..<newCount).map { IndexPath(item: $0, section: 0) }
            
            uiView.performBatchUpdates({
                uiView.insertItems(at: newIndexPaths)
            }, completion: nil)
        } else {
            // For any other change, update coordinator and do full reload
            context.coordinator.gifs = gifs
            
            if let layout = uiView.collectionViewLayout as? WaterfallLayout {
                layout.invalidateLayout()
            }
            
            uiView.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            gifs: gifs,
            isLoadingMore: isLoadingMore,
            onGifSelected: onGifSelected,
            onLoadMore: onLoadMore
        )
    }

    class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSource, WaterfallLayoutDelegate {
        var gifs: [TenorGif]
        var isLoadingMore: Bool
        let onGifSelected: (TenorGif) -> Void
        let onLoadMore: () -> Void

        init(gifs: [TenorGif], isLoadingMore: Bool, onGifSelected: @escaping (TenorGif) -> Void, onLoadMore: @escaping () -> Void) {
            self.gifs = gifs
            self.isLoadingMore = isLoadingMore
            self.onGifSelected = onGifSelected
            self.onLoadMore = onLoadMore
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            gifs.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: GifCollectionViewCell.reuseIdentifier,
                for: indexPath
            ) as? GifCollectionViewCell else {
                return UICollectionViewCell()
            }

            let gif = gifs[indexPath.item]
            cell.configure(with: gif)

            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            let gif = gifs[indexPath.item]
            onGifSelected(gif)
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // Trigger pagination when near the end
            if indexPath.item >= gifs.count - 5 && !isLoadingMore {
                onLoadMore()
            }
        }

        func collectionView(_ collectionView: UICollectionView, aspectRatioForItemAt indexPath: IndexPath) -> CGFloat {
            let gif = gifs[indexPath.item]

            // Try to get aspect ratio from media formats
            if let nanoGif = gif.media_formats.nanogif {
                let dims = nanoGif.dims
                if dims.count == 2, dims[1] > 0 {
                    return CGFloat(dims[0]) / CGFloat(dims[1])
                }
            } else if let gifFormat = gif.media_formats.gif {
                let dims = gifFormat.dims
                if dims.count == 2, dims[1] > 0 {
                    return CGFloat(dims[0]) / CGFloat(dims[1])
                }
            }

            // Default to square if no dimensions available
            return 1.0
        }
    }
}

// MARK: - Collection View Cell

final class GifCollectionViewCell: UICollectionViewCell {
    static let reuseIdentifier = "GifCollectionViewCell"

    private let hostingController = UIHostingController(rootView: AnyView(EmptyView()))
    private var currentGifId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupHostingController()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHostingController() {
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    func configure(with gif: TenorGif) {
        // Only update if the GIF actually changed
        guard currentGifId != gif.id else { return }
        
        currentGifId = gif.id
        
        let gifView = GifVideoView(gif: gif, onTap: {})
            .disabled(true) // Disable tap since we handle it at cell level
            .opacity(1.0) // Explicit opacity to prevent fade issues
            .id(gif.id) // Force SwiftUI to recreate view when GIF changes

        hostingController.rootView = AnyView(gifView)
        
        // Ensure cell visibility is always full
        contentView.alpha = 1.0
        alpha = 1.0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentGifId = nil
        hostingController.rootView = AnyView(EmptyView())
        
        // Reset opacity to prevent artifacts
        contentView.alpha = 1.0
        alpha = 1.0
    }
}
