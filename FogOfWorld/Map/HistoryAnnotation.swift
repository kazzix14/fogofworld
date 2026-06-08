import MapKit
import UIKit

final class HistoryAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var timeString: String
    var speedString: String?
    // 度。nil の場合は方向不定 (停止中もしくは course 未取得)。
    var course: Double?
    // ビューへ直接ラベル更新を伝播するための弱参照。MapKit は timeString の KVO を見ないため必要。
    weak var view: HistoryAnnotationView?

    init(coordinate: CLLocationCoordinate2D, timeString: String, speedString: String? = nil, course: Double? = nil) {
        self.coordinate = coordinate
        self.timeString = timeString
        self.speedString = speedString
        self.course = course
    }

    @MainActor
    func update(coordinate: CLLocationCoordinate2D, timeString: String, speedString: String?, course: Double?) {
        // @objc dynamic な coordinate の setter で KVO 通知は自動発火するため
        // 手動の willChangeValue/didChangeValue は不要。二重発火させると MapKit の
        // KVO 登録状態が壊れ、removeAnnotation 時に "not registered as an observer" 例外を出す。
        self.coordinate = coordinate
        self.timeString = timeString
        self.speedString = speedString
        self.course = course
        view?.applyAnnotation()
    }
}

final class HistoryAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "HistoryAnnotationView"

    private let label = UILabel()
    private let speedLabel = UILabel()
    private let dot = UIView()
    private let arrow = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setup()
        // didSet observer は super.init 中に発火しないため、register 経由で生成された初回ビューには
        // annotation.view が紐付かない。明示的にバインドして update() からのラベル反映経路を担保する。
        if let ann = annotation as? HistoryAnnotation {
            ann.view = self
        }
        applyAnnotation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
        if let ann = annotation as? HistoryAnnotation {
            ann.view = self
        }
        applyAnnotation()
    }

    override var annotation: MKAnnotation? {
        didSet {
            if let ann = annotation as? HistoryAnnotation {
                ann.view = self
            }
            applyAnnotation()
        }
    }

    private func setup() {
        canShowCallout = false
        backgroundColor = .clear
        // speedLabel 分の高さを確保。speedLabel は内容無しの時も spacing が崩れないよう
        // 固定高さで占めるが isHidden で透明にする。
        frame = CGRect(x: 0, y: 0, width: 96, height: 60)
        centerOffset = CGPoint(x: 0, y: -18) // インジケータ中心を coordinate に合わせる

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .label
        label.backgroundColor = .clear
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.white.cgColor
        label.layer.shadowOpacity = 1.0
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        speedLabel.font = .systemFont(ofSize: 10, weight: .medium)
        speedLabel.textColor = .secondaryLabel
        speedLabel.backgroundColor = .clear
        speedLabel.textAlignment = .center
        speedLabel.layer.shadowColor = UIColor.white.cgColor
        speedLabel.layer.shadowOpacity = 1.0
        speedLabel.layer.shadowRadius = 2
        speedLabel.layer.shadowOffset = .zero
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(speedLabel)

        dot.backgroundColor = .systemOrange
        dot.layer.cornerRadius = 8
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        // 矢印は SF Symbol の location.north.fill。デフォルトで北向きのため
        // transform で course (度, 北=0, 時計回り) に合わせて回転する。
        let arrowConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        arrow.image = UIImage(systemName: "location.north.fill", withConfiguration: arrowConfig)
        arrow.tintColor = .systemOrange
        arrow.contentMode = .center
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.isHidden = true
        addSubview(arrow)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.heightAnchor.constraint(equalToConstant: 16),
            speedLabel.topAnchor.constraint(equalTo: label.bottomAnchor),
            speedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            speedLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            speedLabel.heightAnchor.constraint(equalToConstant: 14),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.topAnchor.constraint(equalTo: speedLabel.bottomAnchor, constant: 4),
            dot.widthAnchor.constraint(equalToConstant: 16),
            dot.heightAnchor.constraint(equalToConstant: 16),
            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 20),
            arrow.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func applyAnnotation() {
        guard let ann = annotation as? HistoryAnnotation else { return }
        label.text = ann.timeString
        speedLabel.text = ann.speedString
        speedLabel.isHidden = (ann.speedString == nil)
        if let course = ann.course {
            // 進行方向あり: ドットを隠して矢印を course 度回転表示。
            // 360 超など想定外の値が来ても破綻しないよう mod 360 で正規化する。
            let normalized = course.truncatingRemainder(dividingBy: 360)
            dot.isHidden = true
            arrow.isHidden = false
            arrow.transform = CGAffineTransform(rotationAngle: CGFloat(normalized) * .pi / 180)
        } else {
            dot.isHidden = false
            arrow.isHidden = true
            arrow.transform = .identity
        }
    }
}
