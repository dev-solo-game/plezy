import React, { useRef } from 'react';

interface ModalBackdropProps {
  onClose?: () => void;
  subModal?: boolean;
  className?: string;
  style?: React.CSSProperties;
  children: React.ReactNode;
}

export const ModalBackdrop: React.FC<ModalBackdropProps> = ({
  onClose,
  subModal = false,
  className = '',
  style,
  children,
}) => {
  const pointerDownOnSelfRef = useRef(false);
  const pointerUpOnSelfRef = useRef(false);

  return (
    <div
      className={`modal-backdrop${subModal ? ' sub-modal' : ''}${className ? ` ${className}` : ''}`}
      style={style}
      onPointerDown={(e) => {
        pointerDownOnSelfRef.current =
          e.target === e.currentTarget && (e.pointerType !== 'mouse' || e.button === 0);
        pointerUpOnSelfRef.current = false;
      }}
      onPointerUp={(e) => {
        pointerUpOnSelfRef.current =
          e.target === e.currentTarget && (e.pointerType !== 'mouse' || e.button === 0);
      }}
      onPointerCancel={() => {
        pointerDownOnSelfRef.current = false;
        pointerUpOnSelfRef.current = false;
      }}
      onClick={(e) => {
        const shouldClose =
          pointerDownOnSelfRef.current &&
          pointerUpOnSelfRef.current &&
          e.target === e.currentTarget;
        pointerDownOnSelfRef.current = false;
        pointerUpOnSelfRef.current = false;
        if (shouldClose) {
          onClose?.();
        }
      }}
    >
      {children}
    </div>
  );
};
