import React, { useCallback, useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { Loader2, RefreshCw, Smartphone, X } from 'lucide-react';
import { api } from '../api/client';
import { useApp } from '../contexts/AppContext';

interface QuarkQrModalProps {
  mode: 'pc' | 'web';
  onClose: () => void;
  onSuccess: (secret: string) => void;
}

export const QuarkQrModal: React.FC<QuarkQrModalProps> = ({ mode, onClose, onSuccess }) => {
  const { toast } = useApp();
  const [qrImgUrl, setQrImgUrl] = useState('');
  const [sessionId, setSessionId] = useState('');
  const [expiresAt, setExpiresAt] = useState(0);
  const [remainSec, setRemainSec] = useState(0);
  const [status, setStatus] = useState<'loading' | 'waiting' | 'expired' | 'error'>('loading');
  const [statusMsg, setStatusMsg] = useState('正在获取登录二维码...');

  const startQr = useCallback(async () => {
    setStatus('loading');
    setStatusMsg('正在生成二维码...');
    setQrImgUrl('');
    setSessionId('');
    try {
      const res = await api.quarkQrStart(mode);
      const url = await QRCode.toDataURL(res.qr_content, { width: 224, margin: 2 });
      setQrImgUrl(url);
      setSessionId(res.session_id);
      setExpiresAt(res.expires_at);
      setRemainSec(Math.max(0, Math.round((res.expires_at - Date.now()) / 1000)));
      setStatus('waiting');
      setStatusMsg('请打开手机夸克 App 扫描下方二维码并确认登录');
    } catch (err) {
      setStatus('error');
      setStatusMsg((err as Error).message || '获取二维码失败');
    }
  }, [mode]);

  useEffect(() => {
    void startQr();
  }, [startQr]);

  useEffect(() => {
    if (status !== 'waiting' || !expiresAt) return;
    const tick = window.setInterval(() => {
      const left = Math.max(0, Math.round((expiresAt - Date.now()) / 1000));
      setRemainSec(left);
      if (left <= 0) {
        setStatus('expired');
        setStatusMsg('二维码已过期，请点击刷新重试');
      }
    }, 1000);
    return () => window.clearInterval(tick);
  }, [status, expiresAt]);

  useEffect(() => {
    if (status !== 'waiting' || !sessionId) return;
    let active = true;
    const pollTimer = window.setInterval(async () => {
      try {
        const res = await api.quarkQrPoll(sessionId);
        if (!active) return;
        if (res.status === 'confirmed' && res.secret) {
          toast('夸克扫码授权成功', 'success');
          onSuccess(res.secret);
          onClose();
        } else if (res.status === 'expired') {
          setStatus('expired');
          setStatusMsg('二维码已过期，请点击刷新二维码');
          setSessionId('');
        }
      } catch (err) {
        if (active) {
          setStatus('error');
          setStatusMsg((err as Error).message);
        }
      }
    }, 2000);

    return () => {
      active = false;
      window.clearInterval(pollTimer);
    };
  }, [status, sessionId, onSuccess, onClose, toast]);

  return (
    <div className="modal-backdrop sub-modal" onClick={onClose}>
      <div
        className="modal-panel"
        style={{ maxWidth: 400 }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="modal-header">
          <div className="flex-row" style={{ gap: 8 }}>
            <Smartphone size={17} style={{ color: 'var(--accent)' }} />
            <h3>夸克扫码登录（{mode === 'pc' ? 'PC 令牌模式' : 'Web 模式'}）</h3>
          </div>
          <button type="button" className="btn btn-icon btn-sm" onClick={onClose}>
            <X size={16} />
          </button>
        </div>

        <div className="modal-body" style={{ alignItems: 'center', textAlign: 'center', padding: '24px 20px' }}>
          <div
            style={{
              width: 236,
              height: 236,
              borderRadius: 16,
              background: '#fff',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: 8,
              boxShadow: '0 10px 30px rgba(0, 0, 0, 0.4)',
            }}
          >
            {status === 'loading' ? (
              <Loader2 size={32} className="spin" style={{ color: '#222' }} />
            ) : qrImgUrl ? (
              <img src={qrImgUrl} alt="夸克扫码登录" style={{ width: '100%', height: '100%', borderRadius: 10 }} />
            ) : (
              <span style={{ color: '#444', fontSize: 13 }}>二维码加载失败</span>
            )}
          </div>

          <div style={{ fontSize: 13, color: status === 'error' ? 'var(--danger)' : 'var(--text-secondary)' }}>
            {statusMsg}
          </div>

          {status === 'waiting' && remainSec > 0 && (
            <div className="muted-sm">剩余有效时间：{remainSec} 秒</div>
          )}

          <button type="button" className="btn btn-sm" onClick={() => void startQr()}>
            <RefreshCw size={14} />
            刷新二维码
          </button>
        </div>
      </div>
    </div>
  );
};
