import SwiftUI

struct DetailedAdjustmentsView: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
        Group {
            VStack(alignment:.leading,spacing:18) {
                HStack {Text("节点与分区").font(.headline);Spacer();Button("快照") {store.snapshot()}.disabled(store.current==nil)}
                if let photo=store.current {
                    node("参考匹配",key:"match") {
                        control("强度",key:\.matchStrength,range:0...1)
                        Text("学习颜色与影调，光线方向和光比保持原样。").font(.caption).foregroundStyle(.secondary)
                        ForEach(RegionNames.all,id:\.self) {region in
                            if photo.parameters.regions[region] != nil {regionControls(region)}
                        }
                        ForEach(store.matchNotes,id:\.self) {Text($0).font(.caption).foregroundStyle(.secondary)}
                    }
                    node("光",key:"light") {
                        control("曝光",key:\.exposure,range:-3...3)
                        DisclosureGroup("黑白点与去雾") {
                            nodeToggle("黑白点节点",key:"levels")
                            control("黑白点",key:\.blackWhite,range:0...1)
                            nodeToggle("去雾节点",key:"dehaze")
                            Toggle("按场景建议初始强度",isOn:Binding(get:{store.current?.parameters.autoDehaze==true},set:{v in store.change("场景去雾建议"){$0.autoDehaze=v}})).font(.caption)
                            control("去雾",key:\.dehazeAmt,range:0...1)
                            nodeToggle("对比节点",key:"contrast")
                            control("对比",key:\.contrast,range:0...2)
                        }.font(.caption)
                    }
                    node("色",key:"color") {
                        control("饱和",key:\.saturation,range:0...2)
                        control("色温",key:\.temperature,range:-1...1)
                        control("色调",key:\.tint,range:-1...1)
                        DisclosureGroup("创作色彩") {
                            control("阴影色相",key:\.shadowHue,range:-180...180)
                            control("阴影染色",key:\.shadowChroma,range:0...30)
                            control("高光色相",key:\.highlightHue,range:-180...180)
                            control("高光染色",key:\.highlightChroma,range:0...30)
                            control("褪黑",key:\.fade,range:0...1)
                        }.font(.caption)
                    }
                    node("水",key:"water") {
                        waterControl("亮度 L",index:0,range:0...100)
                        DisclosureGroup("色度与纹理") {
                            waterControl("绿 ↔ 红 a",index:1,range:-70...70)
                            waterControl("蓝 ↔ 黄 b",index:2,range:-70...70)
                            control("色度变化",key:\.waterVar,range:0...2)
                        }.font(.caption)
                    }
                    node("天",key:"sky") {control("色相",key:\.skyHue,range:-180...180)}
                    DisclosureGroup("土地与人像") {
                        node("土地",key:"land") {control("秋叶饱和",key:\.autumn,range:0...1)}
                        node("人像",key:"portrait") {
                            Toggle("肤色保护",isOn:Binding(get:{store.current?.parameters.skinProtect ?? true},set:{value in store.change("肤色保护"){$0.skinProtect=value}}))
                            control("轻磨皮",key:\.smooth,range:0...1)
                            control("提亮",key:\.bright,range:0...1)
                        }
                    }.font(.subheadline)
                    Divider()
                    DisclosureGroup("历史与快照") {
                        HStack {Button("撤销"){store.undo()}.disabled(!store.canUndo);Button("重做"){store.redo()}.disabled(!store.canRedo)}
                        ForEach(Array(store.undoChanges.suffix(8).enumerated()),id:\.offset) {_,change in Text(change.label+" · \(change.before.count) 张").font(.caption).foregroundStyle(.secondary)}
                        ForEach(Array(photo.snapshots.enumerated()),id:\.offset) {_,snapshot in Button(snapshot.label){store.restoreSnapshot(snapshot)}.font(.caption)}
                    }
                    Button("重置调色参数") {store.change("重置调色参数"){$0=AdjustmentParameters()}}
                } else {
                    Text("导入照片后，分区与调色参数会显示在这里。").font(.callout).foregroundStyle(.secondary)
                }
            }.disabled(store.controlsBlocked)
        }.background(Color(white:0.15))
    }

    private func control(_ title:String,key:WritableKeyPath<AdjustmentParameters,Double>,range:ClosedRange<Double>)->some View {
        ValueSlider(title:title,value:Binding(get:{store.current?.parameters[keyPath:key] ?? range.lowerBound},set:{v in
            store.beginEditing(title);store.update{
                $0[keyPath:key]=v
                if key == \AdjustmentParameters.dehazeAmt {$0.autoDehaze=false}
            }
        }),range:range,onEnd:store.finishEditing)
    }

    private func waterControl(_ title:String,index:Int,range:ClosedRange<Double>)->some View {
        ValueSlider(title:title,value:Binding(get:{store.current?.parameters.water[index] ?? 0},set:{v in
            store.beginEditing("水色");store.update{$0.water[index]=v}
        }),range:range,onEnd:store.finishEditing)
    }

    private func nodeToggle(_ title:String,key:String)->some View {
        Toggle(title,isOn:Binding(get:{store.current?.parameters.enabled[key] ?? true},set:{v in store.change(title){$0.enabled[key]=v}})).font(.caption)
    }

    private func node<Content:View>(_ title:String,key:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:8) {
            Toggle(isOn:Binding(get:{store.current?.parameters.enabled[key] ?? true},set:{v in store.change(title+"节点"){$0.enabled[key]=v}})) {
                Text(title).font(.subheadline.weight(.semibold))
            }.toggleStyle(.switch).controlSize(.mini)
            content().opacity((store.current?.parameters.enabled[key] ?? true) ? 1:0.45)
        }
    }

    private func regionControls(_ region:String)->some View {
        DisclosureGroup(RegionNames.title(region)+" · 反推数值") {
            ForEach(0..<3,id:\.self) {index in
                ValueSlider(title:["目标 L","目标 a","目标 b"][index],value:Binding(get:{store.current?.parameters.regions[region]?.mean[index] ?? 0},set:{v in
                    store.beginEditing("反推"+RegionNames.title(region));store.update{$0.regions[region]?.mean[index]=v}
                }),range:index==0 ? 0...100 : -100...100,onEnd:store.finishEditing)
            }
            ForEach(0..<2,id:\.self) {index in
                ValueSlider(title:index==0 ? "a 色度变化":"b 色度变化",value:Binding(get:{store.current?.parameters.regions[region]?.chromaScale[index] ?? 1},set:{v in
                    store.beginEditing("区域色度");store.update{$0.regions[region]?.chromaScale[index]=v}
                }),range:0.25...2,onEnd:store.finishEditing)
            }
            if let p=store.current?.parameters.regions[region] {
                ToneCurve(x:p.lumaX,y:p.lumaY).frame(height:70)
                DisclosureGroup("影调曲线数值") {
                    ForEach(p.lumaY.indices,id:\.self) {i in
                        let lower=i==0 ? 0:min(100,p.lumaY[i-1]+0.01)
                        let upper=i==p.lumaY.count-1 ? 100:max(lower,min(100,p.lumaY[i+1]-0.01))
                        ValueSlider(title:String(format:"输入 %.0f",p.lumaX[i]),value:Binding(get:{store.current?.parameters.regions[region]?.lumaY[i] ?? 0},set:{v in
                            store.beginEditing("区域影调曲线");store.update{$0.regions[region]?.lumaY[i]=v}
                        }),range:lower...max(lower+0.001,upper),onEnd:store.finishEditing)
                    }
                }
            }
        }.font(.caption)
    }

}

struct ValueSlider:View {
    let title:String
    @Binding var value:Double
    let range:ClosedRange<Double>
    var onEnd:()->Void
    var body:some View {
        VStack(spacing:3) {
            HStack {Text(title);Spacer();Text(value,format:.number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(.secondary)}.font(.caption)
            Slider(value:$value,in:range,onEditingChanged:{editing in if !editing {onEnd()}})
                .controlSize(.small).accessibilityLabel(title)
        }
    }
}

struct ToneCurve:View {
    let x:[Double]
    let y:[Double]
    var body:some View {
        GeometryReader {geometry in
            Path {path in
                for i in x.indices {
                    let point=CGPoint(x:x[i]/100*geometry.size.width,y:(1-y[i]/100)*geometry.size.height)
                    if i==0 {path.move(to:point)} else {path.addLine(to:point)}
                }
            }.stroke(Color(white:0.8),lineWidth:1.5)
        }.padding(6).background(Color(white:0.12)).accessibilityLabel("反推影调曲线，可展开查看和调整每个节点")
    }
}
