package account

import "plezy/media_library/internal/db"

const (
	PermBrowse          = 1 << 0
	PermUploadFacts     = 1 << 1
	PermManageSources   = 1 << 2
	PermManageMembers   = 1 << 3
	PermManageSettings  = 1 << 4
	PermDeleteHousehold = 1 << 5

	PermAll = PermBrowse |
		PermUploadFacts |
		PermManageSources |
		PermManageMembers |
		PermManageSettings |
		PermDeleteHousehold
)

const (
	RoleOwner  = "owner"
	RoleAdmin  = "admin"
	RoleMember = "member"
	RoleChild  = "child"
)

const (
	LoginModeHousehold  = "household"
	LoginModeMemberOnly = "member_only"
)

// Principal represents an authenticated household/member session from an opaque usr_ token.
type Principal struct {
	TokenID          string `json:"token_id"`
	HouseholdID      string `json:"household_id"`
	OwnerAccountID   string `json:"owner_account_id"`
	MemberID         string `json:"member_id"`
	Nickname         string `json:"nickname"`
	DeviceID         string `json:"device_id"`
	DeviceClass      string `json:"device_class"`
	Role             string `json:"role"`
	Permissions      int    `json:"permissions"`
	RestrictSources  bool   `json:"restrict_sources"`
	MaxContentRating string `json:"max_content_rating,omitempty"`
	LoginMode        string `json:"login_mode"`
	ExpiresAt        int64  `json:"expires_at"`
}

// HasPerm reports whether the principal grants all bits in perm.
func (p *Principal) HasPerm(perm int) bool {
	if p == nil {
		return false
	}
	if p.Role == RoleOwner {
		return true
	}
	return (p.Permissions & perm) == perm
}

// IsValidRole checks whether role is a supported household member role.
func IsValidRole(role string) bool {
	switch role {
	case RoleOwner, RoleAdmin, RoleMember, RoleChild:
		return true
	default:
		return false
	}
}

// DefaultPermissionsForRole returns the baseline permission mask for a role.
func DefaultPermissionsForRole(role string) int {
	switch role {
	case RoleOwner:
		return PermAll
	case RoleAdmin:
		return PermBrowse | PermUploadFacts | PermManageSources | PermManageMembers | PermManageSettings
	case RoleMember:
		return PermBrowse | PermUploadFacts
	case RoleChild:
		return PermBrowse
	default:
		return PermBrowse
	}
}

// SanitizePermissionsForRole bounds a requested permission bitmask to the ceiling allowed for role.
func SanitizePermissionsForRole(role string, requested int) int {
	switch role {
	case RoleOwner:
		return PermAll
	case RoleAdmin:
		return requested & (PermAll &^ PermDeleteHousehold)
	case RoleMember:
		return requested & (PermBrowse | PermUploadFacts | PermManageSources)
	case RoleChild:
		return requested & PermBrowse
	default:
		return requested & PermBrowse
	}
}

// IsValidDeviceClass checks whether deviceClass matches a recognized client device class.
func IsValidDeviceClass(deviceClass string) bool {
	switch deviceClass {
	case db.DeviceClassDesktop, db.DeviceClassPhone, db.DeviceClassTablet, db.DeviceClassTV, db.DeviceClassWeb:
		return true
	default:
		return false
	}
}
