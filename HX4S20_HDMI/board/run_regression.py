from pathlib import Path
import subprocess
import shutil
import json
import sys
base=Path(__file__).resolve().parent.parent
# 临时副本必须放在工程目录内：本机沙箱下子进程无法进入系统临时目录。
scratch=base/'board'/'sim_work'/'bmp_scratch'
compiler=Path('C:/iverilog/bin/iverilog.exe')
runtime=compiler.with_name('vvp.exe')
results=[]
def run(name, files, args=(), cflags=()):
    output=base/'board/tests'/(name+'.vvp')
    subprocess.run([str(compiler),'-g2012',*cflags,'-s',name,'-o',str(output),*files],cwd=base,check=True,capture_output=True,text=True)
    result=subprocess.run([str(runtime),str(output),*args],cwd=base,capture_output=True,text=True)
    print(result.stdout,end='')
    results.append({'test':name,'arguments':list(args),'returncode':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
    failed_assertion = any(line.startswith('FAIL') for line in result.stdout.splitlines())
    if result.returncode or failed_assertion: raise RuntimeError(name+' failed')
run('tb_sd_card_bmp_control',['board/tests/tb_sd_card_bmp_control.v','SD/sd_card_bmp.v'])
run('tb_video_axis',['board/tests/tb_video_axis.v','video_rgb_to_axis_640x480.v'])
run('tb_pcm_ring_buffer',['board/tests/tb_pcm_ring_buffer.v','audio/pcm_ring_buffer.v'])
run('tb_sd_adapter_three_owner',['board/tests/tb_sd_adapter_three_owner.v','SD/sd_sector_adapter.v'])
run('tb_audio_source_mux',['board/tests/tb_audio_source_mux.v','audio/audio_source_mux.v'])
run('tb_audio_page_gate',['board/tests/tb_audio_page_gate.v','audio/audio_page_gate.v'])
run('tb_scanner_pcm',['board/tests/tb_scanner_pcm.v','SD/fat32_volume_scanner.v'])
run('tb_audio_waveform',['board/tests/tb_audio_waveform.v','display/audio_waveform_overlay.v'])
run('tb_audio_subsystem',[
    'board/tests/tb_audio_subsystem.v',
    'audio/audio_page_gate.v','audio/pcm_stream_player.v','audio/pcm_ring_buffer.v',
    'audio/audio_source_mux.v','SD/fat32_file_streamer.v'
])
run('tb_audio_repeat_switch',[
    'board/tests/tb_audio_repeat_switch.v',
    'audio/audio_page_gate.v','audio/pcm_stream_player.v','audio/pcm_ring_buffer.v',
    'audio/audio_source_mux.v','SD/fat32_file_streamer.v'
])
run('tb_pcm_abort_timing',[
    'board/tests/tb_pcm_abort_timing.v',
    'audio/pcm_stream_player.v','audio/pcm_ring_buffer.v','SD/fat32_file_streamer.v'
])
run('tb_pcm_stream_player',[
    'board/tests/tb_pcm_stream_player.v',
    'audio/pcm_stream_player.v','audio/pcm_ring_buffer.v','SD/fat32_file_streamer.v'
])
run('tb_audio',['board/tests/tb_audio.v','hdmi_audio_tone_i2s_64fs.v','I2S_receiver.v'])
run('tb_audio_pcm',['board/tests/tb_audio_pcm.v','pcm_test_tone.v','audio_arc_calculate.v'])
run('tb_audio_media_cdc',['board/tests/tb_audio_media_cdc.v','state_code_media_cdc.v'])
run('tb_reset',['board/tests/tb_reset.v','board/hx4s20_board_top.v'])
run('tb_startup_sequence',['board/tests/tb_startup_sequence.v','board/hx4s20_board_top.v','SD/sd_card_bmp.v'])
run('tb_frame_ack',['board/tests/tb_frame_ack.v','SD/frame_read_write.v','SD/frame_fifo_read.v','SD/frame_fifo_write.v'])
run('tb_four_bank_frame_commit',['board/tests/tb_four_bank_frame_commit.v','SD/four_bank_frame_commit.v'])
run('tb_four_bank_frame_ctrl',['board/tests/tb_four_bank_frame_ctrl.v','SD/four_bank_frame_ctrl.v'])
run('tb_osd_font',['board/tests/tb_osd_font.v','display/osd_font_rom.v'])
run('tb_osd_status_cdc',['board/tests/tb_osd_status_cdc.v','display/osd_status_cdc.v'])
run('tb_osd_error_code',[
    'board/tests/tb_osd_error_code.v',
    'SD/sd_card_bmp.v', 'SD/bmp_read.v', 'SD/sd_card_top.v',
    'SD/sd_card_cmd.v', 'SD/sd_card_sec_read_write.v', 'SD/spi_master.v'
])
run('tb_osd_video_pipeline',[
    'board/tests/tb_osd_video_pipeline.v',
    'display/osd_overlay.v', 'display/osd_font_rom.v',
    'SD/video_timing_data.v', 'SD/color_bar.v', 'SD/video_delay.v'
],cflags=['-I','SD'])
run('tb_commit_read_index',[
    'board/tests/tb_commit_read_index.v',
    'SD/video_timing_data.v', 'SD/color_bar.v',
    'SD/four_bank_frame_commit.v', 'SD/frame_fifo_read.v'
],cflags=['-I','SD'])
run('tb_video_effect',['board/tests/tb_video_effect.v','display/video_effect.v'])
run('tb_key_event',['board/tests/tb_key_event.v','display/key_event.v'])
run('tb_menu_control',[
    'board/tests/tb_menu_control.v','display/menu_control.v','display/key_event.v'
])
run('tb_menu_cjk_rom',['board/tests/tb_menu_cjk_rom.v','display/menu_cjk_rom.v'])
run('tb_soldout_overlay',[
    'board/tests/tb_soldout_overlay.v',
    'display/soldout_overlay.v','display/menu_cjk_rom.v','display/menu_band_font.v'
],cflags=['-I','include'])
run('tb_menu_pipeline',[
    'board/tests/tb_menu_pipeline.v',
    'display/soldout_overlay.v','display/menu_cjk_rom.v','display/menu_band_font.v',
    'display/video_effect.v','display/osd_overlay.v','display/osd_font_rom.v',
    'SD/video_timing_data.v','SD/video_delay.v','SD/color_bar.v'
],cflags=['-I','include','-I','SD'])
run('tb_video_transition',[
    'board/tests/tb_video_transition.v',
    'display/video_transition.v', 'SD/four_bank_frame_commit.v'
])
run('tb_transition_pipeline',[
    'board/tests/tb_transition_pipeline.v',
    'display/video_effect.v', 'display/video_transition.v',
    'display/osd_overlay.v', 'display/osd_font_rom.v',
    'SD/video_timing_data.v', 'SD/video_delay.v', 'SD/color_bar.v',
    'SD/four_bank_frame_commit.v'
],cflags=['-I','SD'])
run('tb_media_follow_bank',['board/tests/tb_media_follow_bank.v','state_code_media_cdc.v'])
run('tb_top_wiring',[
    'board/tests/tb_top_wiring.v',
    'top_tf_hdmi_audio.v',
    'display/video_effect.v', 'display/video_transition.v',
    'display/osd_overlay.v', 'display/osd_status_cdc.v', 'display/osd_font_rom.v',
    'display/menu_control.v', 'display/key_event.v',
    'display/soldout_overlay.v', 'display/menu_cjk_rom.v', 'display/menu_band_font.v',
    'board/hx4s20_board_top.v',
    'SD/sd_card_bmp.v', 'SD/fat32_bmp_engine.v', 'SD/fat32_volume_scanner.v',
    'SD/fat32_file_streamer.v', 'SD/sd_sector_adapter.v', 'SD/fat32_bmp_parser.v',
    'SD/sd_card_top.v', 'SD/sd_card_cmd.v', 'SD/sd_card_sec_read_write.v', 'SD/spi_master.v',
    'SD/frame_read_write.v', 'SD/frame_fifo_read.v', 'SD/frame_fifo_write.v',
    'IP/afifo_16_32_256.v', 'IP/afifo_32_16_256.v',
    'SD/seg_decoder.v', 'SD/seg_scan.v',
    'SD/video_timing_data.v', 'SD/video_delay.v', 'SD/color_bar.v',
    'SD/four_bank_frame_commit.v',
    'state_code_media_cdc.v', 'pcm_test_tone.v', 'pcm_media_tone.v',
    'audio_arc_calculate.v', 'media_hdmi_audio_bridge.v',
    'startup_pulse.v', 'video_rgb_to_axis_640x480.v',
    'audio/pcm_stream_player.v', 'audio/pcm_ring_buffer.v', 'audio/audio_source_mux.v',
    'display/audio_waveform_overlay.v', 'audio/audio_page_gate.v'
],cflags=['-I','SD','-I','include'])
run('tb_sd_init_sdhc',['board/tests/tb_sd_init_sdhc.v','SD/sd_card_sec_read_write.v'])
run('tb_fat32_bmp_engine',[
    'board/tests/tb_fat32_bmp_engine.v',
    'SD/fat32_bmp_engine.v', 'SD/fat32_volume_scanner.v',
    'SD/fat32_file_streamer.v', 'SD/sd_sector_adapter.v',
    'SD/fat32_bmp_parser.v'
])
run('tb_fat32_real_bmp',[
    'board/tests/tb_fat32_real_bmp.v',
    'SD/fat32_bmp_engine.v', 'SD/fat32_volume_scanner.v',
    'SD/fat32_file_streamer.v', 'SD/sd_sector_adapter.v',
    'SD/fat32_bmp_parser.v'
])
images=Path(sys.argv[1]) if len(sys.argv)>1 else base/'assets/tf'
scratch.mkdir(parents=True,exist_ok=True)
for index in range(1,5):
    image=images/(str(index).zfill(3)+'.bmp')
    target=scratch/'image.bmp'
    shutil.copyfile(image,target)
    run('tb_bmp',['board/tests/tb_bmp.v','SD/bmp_read.v'],['+BMP='+target.as_posix()])
    results[-1]['source_image']=str(image)
(base/'board/regression_results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
print('All targeted regressions passed. Protected IP and physical board are outside this simulation.')
