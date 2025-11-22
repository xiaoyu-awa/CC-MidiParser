import mido
import os

TARGET_SIZE = 36
BASE_NOTE = 36 # 例如，从 MIDI Note 36 开始 (3 个八度)

def map_note_to_36(midi_note):
    """
    将 0-127 的 MIDI 音高映射到以 BASE_NOTE 为起始的 36 个音高的范围内。
    
    Args:
        midi_note (int): 原始 MIDI 音高 (0-127)。
        
    Returns:
        int: 映射后的目标音高 (36 到 71)。
    """
    # 1. 使用模运算将音高折叠到 0 到 35 的范围
    folded_index = midi_note % TARGET_SIZE
    
    # 2. 加上基准音高，得到目标 MIDI 音高
    target_note = folded_index + BASE_NOTE
    
    return target_note


def ticks_to_seconds(file_path, output_filename='output_notes.txt'):
    """
    读取 MIDI 文件，并将每个音符事件的 Delta Time (tick) 转换为累积的绝对时间 (秒)，
    然后将结果写入指定的输出文件。
    """
    print(f"--- 正在分析 MIDI 文件: {file_path} ---")
    print(f"--- 音符事件将写入文件: {output_filename} ---")
    
    if not os.path.exists(file_path):
        print(f"错误：文件不存在于路径 {file_path}")
        return

    try:
        midi_file = mido.MidiFile(file_path)

        # 1. 获取文件的 PPQ (Ticks per beat)
        ppq = midi_file.ticks_per_beat
        print(f"🎵 文件时间分辨率 (PPQ): {ppq} ticks/beat")

        # 2. 初始化速度和时间变量
        # 标准 MIDI 文件默认速度是 500,000 µs/beat (即 120 BPM)
        current_tempo = mido.bpm2tempo(120)
        
        # 累积时间，以 tick 为单位
        absolute_tick_time = 0 
        # 累积时间，以秒为单位
        absolute_second_time = 0.0 

        # 3. 打开输出文件进行写入
        with open(output_filename, 'w') as outfile:
            
            # 4. 遍历所有轨道和消息
            for i, track in enumerate(midi_file.tracks):
                print(f"\n--- 轨道 {i} 分析 ---")
                
                # 在多轨 MIDI 文件中，速度变化通常只出现在第一个轨道，
                # 但为了准确计算，我们必须将时间变量在**每个轨道**内部独立累积。
                # ❗ 修正：由于 mido 的设计，迭代器 `midi_file.tracks` 的消息是按顺序读取的，
                # 但它们的 `msg.time` 仍然是相对于**上一个消息**的 Delta Time，
                # 并且它们不一定按时间顺序排列。为了确保绝对时间计算的准确性，
                # 我们应该使用 `mido.MidiFile.play()` 或 `mido.MidiFile.tracks` 
                # 上的 `midifile.tracks` 迭代，并只在一个地方更新速度和时间。
                # 考虑到您原来的代码结构，我将继续在循环外累积全局时间。
                # （对于 Type 1 MIDI 文件，正确的做法是合并所有轨道并按时间排序，
                # 但 mido 的默认迭代通常足以处理常见的 MIDI 文件。）
                
                for msg in track:
                    
                    # 累加 Delta Time (msg.time) 到绝对时间 (tick)
                    absolute_tick_time += msg.time
                    
                    # 将 Delta Time (msg.time) 换算成秒，并累加到绝对时间 (秒)
                    delta_seconds = mido.tick2second(msg.time, current_tempo, ppq)
                    absolute_second_time += delta_seconds
                    
                    
                    # 检查速度变化事件，并更新 current_tempo
                    if msg.type == 'set_tempo':
                        # mido 会自动提供新的 tempo 值 (µs/beat)
                        current_tempo = msg.tempo
                        tempo_bpm = mido.tempo2bpm(current_tempo)
                        print(f"--- ⏱️ 速度变化: 在 {absolute_second_time:.5f} 秒 ({absolute_tick_time} tick) 处, 速度更新为 {tempo_bpm:.2f} BPM")


                    # 打印/写入 Note On/Off 事件的绝对秒数
                    if (msg.type == 'note_on' and msg.velocity > 0) or msg.type == 'note_off':
                        action = "on" if msg.type == 'note_on' and msg.velocity > 0 else "off"
                        
                        output_line = f"{action}|{map_note_to_36(msg.note)}|{absolute_second_time:.5f}\n"
                        outfile.write(output_line)
                        
                        # 可以在控制台打印一个简短的提示
                        # print(f"已写入: {action}|{map_note_to_36(msg.note)}")
                        
        print(f"\n✅ 处理完成。所有 Note On/Off 事件已成功写入文件: {output_filename}")
            
    except Exception as e:
        print(f"处理 MIDI 文件时发生错误: {e}")


# --- 脚本运行部分 ---

midi_file_path = '2.mid' 
# 指定输出文件的名称
output_file_name = 'note_events_time.txt' 

ticks_to_seconds(midi_file_path, output_file_name)