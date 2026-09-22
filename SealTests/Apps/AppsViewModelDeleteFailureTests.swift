import Foundation
import Testing
@testable import Seal

/// 「删除失败」必须给用户一个能看懂的理由（2026-09-22 用户报「续签和待签名删不掉」）。
///
/// ## 为什么这条值得单独测
///
/// `AppsViewModel.delete(_:)` 的调用点是
/// `Task { _ = await viewModel.delete(app) }` —— **返回值被丢掉了** ✗
/// ⇒ 「删除失败时用户到底能不能看见」这件事，**只取决于失败分支有没有设置
/// `alertFailure`**。它的错法不崩、不编译失败，只在真机上表现为
/// 「点了『删除』，界面毫无反应，App 还在」—— 正是那次报障的形态。
///
/// 所以这里把「提示必须说清两件事」钉住：
/// ① **是谁在占用**（否则用户不知道该等什么）；
/// ② **什么都没发生**（否则用户会以为文件已经被删了）。
@MainActor
@Suite("删除失败的提示")
struct AppsViewModelDeleteFailureTests {
    @Test
    func deleteBlockedFailureNamesTheOperationThatIsRunning() {
        let failure = AppsViewModel.deleteBlockedFailure(activeOperationTitle: "正在续签")
        #expect(failure.code == "SEAL-APP-004")
        #expect(failure.title == "删除没有执行")
        #expect(failure.reason.contains("正在续签"))
        // 「都还在」= 用户最需要知道的那句：删除没有发生，数据没丢。
        #expect(failure.reason.contains("都还在"))
    }

    @Test
    func deleteBlockedFailureStillExplainsWhenTheHolderIsUnknown() {
        let failure = AppsViewModel.deleteBlockedFailure(activeOperationTitle: nil)
        #expect(failure.code == "SEAL-APP-004")
        #expect(failure.reason.isEmpty == false)
        #expect(failure.reason.contains("都还在"))
        #expect(failure.recovery.isEmpty == false)
    }
}
