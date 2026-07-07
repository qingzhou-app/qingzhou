package libXray

// 轻舟本地 patch（非 libXray 上游代码）：SwitchOutbound 的 gomobile 导出。
// 请求/响应封装与上游 invoke.go 的新模型完全一致（#132 之后是纯 JSON，
// 不再 base64）：入参 JSON{outboundJson}，返回 {success, data, error} 信封
//（同包可直接复用 encodeInvokeNoDataResponse）。
// 由 scripts/build-libxray.sh 在 gomobile bind 前复制到 $LIBXRAY_DIR/。
// 不挂进 Invoke 的方法表 —— 那是上游文件，改它会增大每次升级的补丁面；
// 独立导出（LibXraySwitchOutbound）对 Swift 侧一样好用。

import (
	"encoding/json"

	"github.com/xtls/libxray/xray"
)

type switchOutboundRequest struct {
	OutboundJSON string `json:"outboundJson,omitempty"`
}

// SwitchOutbound 原地替换运行中 xray 实例的 outbound handler（换节点不重启）。
// requestJSON: JSON{outboundJson}，outboundJson 是 xray 配置 outbounds
// 数组的单个元素（含 tag）。
func SwitchOutbound(requestJSON string) string {
	var request switchOutboundRequest
	if err := json.Unmarshal([]byte(requestJSON), &request); err != nil {
		return encodeInvokeNoDataResponse(err)
	}
	return encodeInvokeNoDataResponse(xray.SwitchOutbound(request.OutboundJSON))
}
