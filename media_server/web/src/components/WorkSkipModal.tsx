import React, { useState } from 'react';
import { Loader2, X } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';
import type { WorkPrefs } from '../types';
import { CustomSelect } from './CustomSelect';

interface WorkSkipModalProps {
  workKey: string;
  initialPrefs?: WorkPrefs | null;
  onClose: () => void;
  onSaved: (wp: WorkPrefs) => void;
}

export const WorkSkipModal: React.FC<WorkSkipModalProps> = ({ workKey, initialPrefs, onClose, onSaved }) => {
  const { toast } = useApp();
  const [introEnabled, setIntroEnabled] = useState(initialPrefs?.intro_enabled ?? false);
  const [introStartSec, setIntroStartSec] = useState(Math.round((initialPrefs?.intro_start_ms || 0) / 1000));
  const [introEndSec, setIntroEndSec] = useState(Math.round((initialPrefs?.intro_end_ms || 90000) / 1000));
  const [creditsEnabled, setCreditsEnabled] = useState(initialPrefs?.credits_enabled ?? false);
  const [creditsFromEndSec, setCreditsFromEndSec] = useState(Math.round((initialPrefs?.credits_from_end_ms || 90000) / 1000));
  const [keepEasterEggSec, setKeepEasterEggSec] = useState(Math.round((initialPrefs?.keep_easter_egg_ms || 0) / 1000));
  const [speed, setSpeed] = useState(initialPrefs?.playback_speed || 1);
  const [saving, setSaving] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      const res = await api.saveWorkPrefs({
        work_key: workKey,
        intro_enabled: introEnabled,
        intro_start_ms: Math.max(0, introStartSec * 1000),
        intro_end_ms: Math.max(0, introEndSec * 1000),
        credits_enabled: creditsEnabled,
        credits_from_end_ms: Math.max(0, creditsFromEndSec * 1000),
        keep_easter_egg_ms: Math.max(0, keepEasterEggSec * 1000),
        playback_speed: speed || 1,
      });
      toast('片头片尾跳过偏好已保存', 'success');
      onSaved(res.work_prefs);
      onClose();
    } catch (err) {
      toast((err as Error).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <form className="modal-panel" style={{ maxWidth: 520 }} onClick={(e) => e.stopPropagation()} onSubmit={handleSubmit}>
        <div className="modal-header">
          <h3>片头 / 片尾跳过与播放偏好</h3>
          <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        <div className="modal-body">
          <div className="card-box" style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
            <label className="flex-row" style={{ cursor: 'pointer', fontWeight: 600 }}>
              <input type="checkbox" checked={introEnabled} onChange={(e) => setIntroEnabled(e.target.checked)} />
              启用片头跳过提示
            </label>
            <div className="grid-2">
              <div className="field">
                <label>片头开始（秒）</label>
                <input
                  className="input"
                  type="number"
                  min={0}
                  value={introStartSec}
                  onChange={(e) => setIntroStartSec(Number(e.target.value))}
                />
              </div>
              <div className="field">
                <label>片头结束（秒）</label>
                <input
                  className="input"
                  type="number"
                  min={0}
                  value={introEndSec}
                  onChange={(e) => setIntroEndSec(Number(e.target.value))}
                />
              </div>
            </div>
          </div>

          <div className="card-box" style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
            <label className="flex-row" style={{ cursor: 'pointer', fontWeight: 600 }}>
              <input type="checkbox" checked={creditsEnabled} onChange={(e) => setCreditsEnabled(e.target.checked)} />
              启用片尾自动提示下一集
            </label>
            <div className="grid-2">
              <div className="field">
                <label>距结尾多少秒开始提示</label>
                <input
                  className="input"
                  type="number"
                  min={0}
                  value={creditsFromEndSec}
                  onChange={(e) => setCreditsFromEndSec(Number(e.target.value))}
                />
              </div>
              <div className="field">
                <label>保留末尾彩蛋（秒）</label>
                <input
                  className="input"
                  type="number"
                  min={0}
                  value={keepEasterEggSec}
                  onChange={(e) => setKeepEasterEggSec(Number(e.target.value))}
                />
              </div>
            </div>
          </div>

          <div className="field">
            <label>作品默认播放倍速</label>
            <CustomSelect
              value={String(speed)}
              onChange={(v) => setSpeed(Number(v))}
              options={[
                { value: '0.75', label: '0.75x' },
                { value: '1', label: '1.0x（正常）' },
                { value: '1.25', label: '1.25x' },
                { value: '1.5', label: '1.5x' },
                { value: '2', label: '2.0x' },
              ]}
            />
          </div>
        </div>

        <div className="modal-footer">
          <button type="button" className="btn" onClick={onClose}>
            取消
          </button>
          <button type="submit" className="btn btn-primary" disabled={saving}>
            {saving && <Loader2 size={14} className="spin" />}
            保存设置
          </button>
        </div>
      </form>
    </div>
  );
};
