import React, { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import {
  Activity,
  Edit3,
  ExternalLink,
  Loader2,
  Plus,
  Power,
  Server,
  Trash2,
} from 'lucide-react';
import { api, extServerKindLabel } from '../api/client';
import { useSWRQuery } from '../api/queryCache';
import { ExternalServerEditorModal } from '../components/ExternalServerEditorModal';
import { CardListSkeleton } from '../components/Skeletons';
import { useApp } from '../contexts/AppContext';
import type { ExternalServerRecord } from '../types';

export const ExternalServersManagePage: React.FC = () => {
  const { toast, refreshExternalServers } = useApp();
  const [searchParams, setSearchParams] = useSearchParams();
  const [showCreate, setShowCreate] = useState(() => searchParams.get('add') === '1');
  const [editingServer, setEditingServer] = useState<ExternalServerRecord | null>(null);
  const [testingId, setTestingId] = useState<string>('');

  useEffect(() => {
    if (searchParams.get('add') === '1') {
      setShowCreate(true);
      setSearchParams(
        (prev) => {
          const p = new URLSearchParams(prev);
          p.delete('add');
          return p;
        },
        { replace: true }
      );
    }
  }, [searchParams, setSearchParams]);

  const {
    data: servers = [],
    showSkeleton,
    reload,
  } = useSWRQuery<ExternalServerRecord[]>(
    'ext:servers',
    () => api.listExternalServers().then((r) => r.servers || []),
    {
      onError: (err) => toast(err.message, 'error'),
    }
  );

  const handleToggleEnabled = async (srv: ExternalServerRecord) => {
    try {
      await api.updateExternalServer(srv.id, { enabled: !srv.enabled });
      toast(srv.enabled ? `已停用「${srv.name}」` : `已启用「${srv.name}」`, 'success');
      await Promise.all([reload(), refreshExternalServers()]);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  const handleTest = async (srv: ExternalServerRecord) => {
    setTestingId(srv.id);
    try {
      const res = await api.testExternalServer({
        id: srv.id,
        kind: srv.kind,
        base_url: srv.base_url,
        auth_mode: srv.auth_mode,
        username: srv.username,
        user_id: srv.user_id,
        allow_insecure_tls: srv.allow_insecure_tls,
      });
      toast(`「${srv.name}」连通正常 · ${res.version || ''} (${res.latency_ms}ms)`, 'success');
    } catch (err) {
      toast(`「${srv.name}」连接失败：${(err as Error).message}`, 'error');
    } finally {
      setTestingId('');
    }
  };

  const handleDelete = async (srv: ExternalServerRecord) => {
    if (!window.confirm(`确认删除外部服务器「${srv.name}」？这仅移除本地连接配置，不会改动远端服务器数据。`)) {
      return;
    }
    try {
      await api.deleteExternalServer(srv.id);
      toast(`已移除「${srv.name}」`, 'success');
      await Promise.all([reload(), refreshExternalServers()]);
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  };

  return (
    <div>
      <div className="section-head" style={{ marginTop: 4 }}>
        <div>
          <h2 className="section-title">外部媒体服务器 (Emby / Jellyfin)</h2>
          <div className="muted-sm" style={{ marginTop: 4 }}>
            独立挂载已有 Emby / Jellyfin 服务器，所有元数据、海报、转码流与观看进度由后端统一代理并与远端双向同步。
          </div>
        </div>
        <button type="button" className="btn btn-primary btn-sm" onClick={() => setShowCreate(true)}>
          <Plus size={15} />
          添加服务器
        </button>
      </div>

      {showSkeleton ? (
        <CardListSkeleton />
      ) : servers.length === 0 ? (
        <div className="card-box" style={{ textAlign: 'center', padding: 52 }}>
          <Server size={38} className="muted" style={{ marginBottom: 12 }} />
          <p className="muted" style={{ marginBottom: 18 }}>
            尚未连接任何外部 Emby 或 Jellyfin 服务器。添加后会在侧边栏「外部媒体服」分类下独立展示。
          </p>
          <button type="button" className="btn btn-primary" onClick={() => setShowCreate(true)}>
            <Plus size={16} />
            立即连接 Emby / Jellyfin
          </button>
        </div>
      ) : (
        <div className="grid-2">
          {servers.map((srv) => (
            <div key={srv.id} className="card-box" style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div className="flex-row" style={{ justifyContent: 'space-between' }}>
                <div className="flex-row" style={{ gap: 8, minWidth: 0 }}>
                  <span className={`tag ${srv.kind}`}>{extServerKindLabel(srv.kind)}</span>
                  <strong style={{ fontSize: 16, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {srv.name}
                  </strong>
                  {!srv.enabled && <span className="tag danger">已停用</span>}
                </div>
                <button
                  type="button"
                  className="btn btn-icon btn-sm"
                  onClick={() => void handleToggleEnabled(srv)}
                  title={srv.enabled ? '停用' : '启用'}
                >
                  <Power size={14} style={{ color: srv.enabled ? 'var(--success)' : 'var(--text-muted)' }} />
                </button>
              </div>

              <div className="muted-sm" style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                <div style={{ wordBreak: 'break-all' }}>地址：{srv.base_url}</div>
                <div>
                  账号：{srv.username || srv.user_id || '-'} · 认证：
                  {srv.auth_mode === 'apikey' ? 'API Key' : 'Access Token'}
                  {srv.server_version ? ` · 版本 v${srv.server_version}` : ''}
                </div>
              </div>

              <div className="flex-row" style={{ gap: 8, marginTop: 'auto', paddingTop: 4 }}>
                {srv.enabled && (
                  <Link to={`/ext/${srv.id}`} className="btn btn-primary btn-sm">
                    <ExternalLink size={13} />
                    进入媒体库
                  </Link>
                )}
                <button
                  type="button"
                  className="btn btn-sm"
                  onClick={() => void handleTest(srv)}
                  disabled={testingId === srv.id}
                >
                  {testingId === srv.id ? <Loader2 size={13} className="spin" /> : <Activity size={13} />}
                  测试连接
                </button>
                <button type="button" className="btn btn-sm" onClick={() => setEditingServer(srv)}>
                  <Edit3 size={13} />
                  编辑
                </button>
                <button
                  type="button"
                  className="btn btn-sm"
                  style={{ color: 'var(--danger)' }}
                  onClick={() => void handleDelete(srv)}
                >
                  <Trash2 size={13} />
                  删除
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {(showCreate || editingServer) && (
        <ExternalServerEditorModal
          server={editingServer}
          onClose={() => {
            setShowCreate(false);
            setEditingServer(null);
          }}
          onSaved={() => void reload()}
        />
      )}
    </div>
  );
};
