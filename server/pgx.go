package main

// PostgreSQL driver wiring.
//
// The rest of this codebase is written with SQLite-style '?' bind
// placeholders. pgx's stdlib adapter does NOT rewrite '?' (it sends the SQL
// verbatim, which fails on PostgreSQL). Instead of editing ~600 placeholder
// sites, we register our own "pgxrw" driver whose Conn wrapper rewrites every
// query string from '?' to $1..$n before delegating to pgx. This catches all
// code paths: Exec / Query / QueryRow / Prepare, inside and outside
// transactions, including the migrations runner.
//
// The rewrite is a naive byte scan. This is safe for this codebase because no
// SQL string literal contains a '?' character; all '?' are bind markers.

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/stdlib"
)

// pgxrwDriver wraps the pgx stdlib driver and rewrites placeholders.
type pgxrwDriver struct {
	inner driver.Driver
}

func (d *pgxrwDriver) Open(name string) (driver.Conn, error) {
	conn, err := d.inner.Open(name)
	if err != nil {
		return nil, err
	}
	return &rewriteConn{Conn: conn}, nil
}

func (d *pgxrwDriver) OpenConnector(name string) (driver.Connector, error) {
	if dc, ok := d.inner.(driver.DriverContext); ok {
		c, err := dc.OpenConnector(name)
		if err != nil {
			return nil, err
		}
		return &rewriteConnector{Connector: c, driver: d}, nil
	}
	return &fallbackConnector{driver: d, name: name}, nil
}

// fallbackConnector is used when the inner driver lacks DriverContext.
type fallbackConnector struct {
	driver *pgxrwDriver
	name   string
}

func (fc *fallbackConnector) Connect(ctx context.Context) (driver.Conn, error) {
	return fc.driver.Open(fc.name)
}

func (fc *fallbackConnector) Driver() driver.Driver { return fc.driver }

// rewriteConnector hands out rewriteConn wrappers.
type rewriteConnector struct {
	driver.Connector
	driver *pgxrwDriver
}

func (c *rewriteConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return &rewriteConn{Conn: conn}, nil
}

func (c *rewriteConnector) Driver() driver.Driver { return c.driver }

// rewriteConn is a driver.Conn that rewrites '?' into $N before delegating.
type rewriteConn struct {
	driver.Conn
}

func (c *rewriteConn) Prepare(query string) (driver.Stmt, error) {
	return c.Conn.Prepare(rebindSQL(query))
}

func (c *rewriteConn) PrepareContext(ctx context.Context, query string) (driver.Stmt, error) {
	if p, ok := c.Conn.(driver.ConnPrepareContext); ok {
		return p.PrepareContext(ctx, rebindSQL(query))
	}
	return c.Prepare(rebindSQL(query))
}

func (c *rewriteConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if e, ok := c.Conn.(driver.ExecerContext); ok {
		return e.ExecContext(ctx, rebindSQL(query), args)
	}
	return nil, driver.ErrSkip
}

func (c *rewriteConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if q, ok := c.Conn.(driver.QueryerContext); ok {
		return q.QueryContext(ctx, rebindSQL(query), args)
	}
	return nil, driver.ErrSkip
}

// CheckNamedValue keeps the underlying converter working through the wrapper.
func (c *rewriteConn) CheckNamedValue(nv *driver.NamedValue) error {
	if nc, ok := c.Conn.(driver.NamedValueChecker); ok {
		return nc.CheckNamedValue(nv)
	}
	v, err := driver.DefaultParameterConverter.ConvertValue(nv.Value)
	if err != nil {
		return err
	}
	nv.Value = v
	return nil
}

// Ping delegates to the underlying connection when supported.
func (c *rewriteConn) Ping(ctx context.Context) error {
	if p, ok := c.Conn.(driver.Pinger); ok {
		return p.Ping(ctx)
	}
	return nil
}

// ResetSession and IsValid forward optional pool hooks.
func (c *rewriteConn) ResetSession(ctx context.Context) error {
	if r, ok := c.Conn.(driver.SessionResetter); ok {
		return r.ResetSession(ctx)
	}
	return nil
}

func (c *rewriteConn) IsValid() bool {
	if v, ok := c.Conn.(driver.Validator); ok {
		return v.IsValid()
	}
	return true
}

func (c *rewriteConn) Begin() (driver.Tx, error) {
	tx, err := c.Conn.Begin()
	if err != nil {
		return nil, err
	}
	return &rewriteTx{Tx: tx}, nil
}

func (c *rewriteConn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	if b, ok := c.Conn.(driver.ConnBeginTx); ok {
		tx, err := b.BeginTx(ctx, opts)
		if err != nil {
			return nil, err
		}
		return &rewriteTx{Tx: tx}, nil
	}
	return c.Begin()
}

// rewriteTx is retained for interface completeness (a no-op wrapper).
type rewriteTx struct {
	driver.Tx
}

// rebindSQL converts '?' placeholders into $1..$n.
func rebindSQL(query string) string {
	var b strings.Builder
	b.Grow(len(query) + 8)
	n := 0
	for i := 0; i < len(query); i++ {
		if query[i] == '?' {
			n++
			b.WriteByte('$')
			b.WriteString(fmt.Sprintf("%d", n))
		} else {
			b.WriteByte(query[i])
		}
	}
	return b.String()
}

func init() {
	// "pgxrw" is the driver name used by openDB for PostgreSQL. Reuse the
	// already-registered pgx driver instance so config registries are shared.
	sql.Register("pgxrw", &pgxrwDriver{inner: stdlib.GetDefaultDriver()})
}
