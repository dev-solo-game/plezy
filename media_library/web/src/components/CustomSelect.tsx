import React, { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Check, ChevronDown } from 'lucide-react';

export interface SelectOption<T extends string | number = string> {
  value: T;
  label: string;
  description?: string;
}

interface CustomSelectProps<T extends string | number = string> {
  value: T;
  onChange: (value: T) => void;
  options: Array<SelectOption<T>>;
  placeholder?: string;
  compact?: boolean;
  disabled?: boolean;
  className?: string;
  style?: React.CSSProperties;
  minMenuWidth?: number;
}

export function CustomSelect<T extends string | number = string>({
  value,
  onChange,
  options,
  placeholder = '请选择',
  compact = false,
  disabled = false,
  className = '',
  style,
  minMenuWidth,
}: CustomSelectProps<T>) {
  const [open, setOpen] = useState(false);
  const [menuStyle, setMenuStyle] = useState<React.CSSProperties>({});
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);

  const selectedOpt = options.find((o) => o.value === value);

  const updatePosition = () => {
    const el = triggerRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const spaceBelow = window.innerHeight - rect.bottom - 12;
    const spaceAbove = rect.top - 12;
    const width = Math.max(rect.width, minMenuWidth || 0);
    const left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));

    if (spaceBelow < 180 && spaceAbove > spaceBelow) {
      setMenuStyle({
        left,
        bottom: window.innerHeight - rect.top + 6,
        minWidth: width,
        maxWidth: Math.min(360, window.innerWidth - 16),
        maxHeight: Math.min(280, spaceAbove),
      });
    } else {
      setMenuStyle({
        left,
        top: rect.bottom + 6,
        minWidth: width,
        maxWidth: Math.min(360, window.innerWidth - 16),
        maxHeight: Math.min(280, Math.max(120, spaceBelow)),
      });
    }
  };

  useLayoutEffect(() => {
    if (open) {
      updatePosition();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: MouseEvent) => {
      const target = e.target as Node;
      if (triggerRef.current?.contains(target) || menuRef.current?.contains(target)) {
        return;
      }
      setOpen(false);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };
    const onScrollOrResize = (e: Event) => {
      if (e.type === 'scroll' && menuRef.current && e.target instanceof Node && menuRef.current.contains(e.target)) {
        return;
      }
      setOpen(false);
    };

    window.addEventListener('mousedown', onPointerDown);
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('resize', onScrollOrResize);
    window.addEventListener('scroll', onScrollOrResize, true);
    return () => {
      window.removeEventListener('mousedown', onPointerDown);
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('resize', onScrollOrResize);
      window.removeEventListener('scroll', onScrollOrResize, true);
    };
  }, [open]);

  return (
    <>
      <button
        ref={triggerRef}
        type="button"
        disabled={disabled}
        className={`custom-select-trigger ${compact ? 'compact' : ''} ${open ? 'open' : ''} ${className}`}
        style={style}
        onClick={() => !disabled && setOpen((v) => !v)}
      >
        <span className="custom-select-label">{selectedOpt ? selectedOpt.label : placeholder}</span>
        <ChevronDown size={14} className="custom-select-chevron" />
      </button>

      {open &&
        createPortal(
          <div ref={menuRef} className="custom-select-menu" style={menuStyle} role="listbox">
            {options.map((opt) => {
              const isSelected = opt.value === value;
              return (
                <button
                  key={String(opt.value)}
                  type="button"
                  role="option"
                  aria-selected={isSelected}
                  className={`custom-select-option ${isSelected ? 'selected' : ''}`}
                  onClick={() => {
                    onChange(opt.value);
                    setOpen(false);
                  }}
                >
                  <div style={{ minWidth: 0 }}>
                    <div>{opt.label}</div>
                    {opt.description && (
                      <div className="muted-sm" style={{ fontSize: 11, marginTop: 1 }}>
                        {opt.description}
                      </div>
                    )}
                  </div>
                  {isSelected && <Check size={14} style={{ flexShrink: 0 }} />}
                </button>
              );
            })}
          </div>,
          document.body
        )}
    </>
  );
}

export interface RadioCardOption<T extends string = string> {
  value: T;
  title: string;
  description?: string;
  badge?: string;
  icon?: React.ReactNode;
  colorDot?: string;
}

interface RadioCardGroupProps<T extends string = string> {
  value: T;
  onChange: (value: T) => void;
  options: Array<RadioCardOption<T>>;
  columns?: 2 | 3 | 4;
  disabled?: boolean;
}

export function RadioCardGroup<T extends string = string>({
  value,
  onChange,
  options,
  columns = 2,
  disabled = false,
}: RadioCardGroupProps<T>) {
  return (
    <div className={`radio-card-grid cols-${columns}`} role="radiogroup">
      {options.map((opt) => {
        const active = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            role="radio"
            aria-checked={active}
            disabled={disabled}
            className={`radio-card ${active ? 'active' : ''}`}
            onClick={() => !disabled && onChange(opt.value)}
          >
            <div className="radio-card-top">
              <div className="radio-card-title-row">
                {opt.colorDot && (
                  <span
                    style={{
                      width: 11,
                      height: 11,
                      borderRadius: '50%',
                      background: opt.colorDot,
                      flexShrink: 0,
                    }}
                  />
                )}
                {opt.icon}
                <span>{opt.title}</span>
                {opt.badge && (
                  <span className="tag accent" style={{ fontSize: 10, padding: '1px 6px' }}>
                    {opt.badge}
                  </span>
                )}
              </div>
              <span className="radio-dot-ring">
                {active && <span className="radio-dot-inner" />}
              </span>
            </div>
            {opt.description && <div className="radio-card-desc">{opt.description}</div>}
          </button>
        );
      })}
    </div>
  );
}
